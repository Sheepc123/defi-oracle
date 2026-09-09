// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title LendingPool —— 极简超额抵押借贷池（抵押 ETH，借出 mUSD）
///
/// @notice 这个合约在实验里的唯一作用，是把 Oracle 的**报价失真**放大成一个
///         可观测、可计价的**协议风险**。它本身不是研究对象。
///
///         传导链条：
///             DEX 储备被操纵 → Oracle 报价升高 → collateralValue 虚高
///             → maxBorrow 虚高 → 攻击者超额借出 mUSD → 报价回落 → 协议留下坏账
///
/// @dev 【刻意不实现的功能，以及原因】
///
///      1. 利息累积（interest accrual）
///         实验的时间跨度是分钟到小时级，利息对结论的影响远小于报价失真，
///         加进来只会让「攻击净利」的计算多一个噪声项。
///
///      2. 清算（liquidation）
///         现实中 Oracle 操纵最常见的变现方式是「把价格打下去，清算别人」。
///         但那需要清算激励、部分清算、拍卖等一整套机制。
///         本实验改用另一条同样真实的路径：「把价格抬上去，超额借款后走人」。
///         结论的可比性不受影响，代码量少一个数量级。
///
///      3. repay / withdraw
///         攻击者不会还款，也不会赎回抵押品 —— 他的最优策略就是弃仓。
///         正常用户的还款路径对本实验没有任何信息量，故省略。
///
///      4. fund() 没有访问控制
///         这是测试脚手架，不是要上主网的合约。加 Ownable 只会增加噪声。
///
///      详见 docs/DESIGN.md §1 的边界表。
contract LendingPool {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────
    // 不变配置
    // ─────────────────────────────────────────────────────────

    /// @notice 借出的稳定币（mUSD）
    IERC20 public immutable stable;

    /// @notice 价格来源。池子**不知道**自己接的是 Spot / TWAP / Aggregated 中的哪一个，
    ///         这正是三组实验条件一致的保证。
    IPriceOracle public immutable oracle;

    /// @notice 抵押率 150%（bps 表示）。
    ///         抵押品价值 1500 mUSD 时，最多借出 1000 mUSD。
    /// @dev 数值越大越保守。150% 是 MakerDAO / Aave 常见档位，
    ///      选它是为了让「超额抵押缓冲能吸收多大的报价失真」这个问题有现实参照。
    uint256 public constant COLLATERAL_RATIO_BPS = 15_000;

    uint256 public constant BPS_DENOM = 10_000;

    // ─────────────────────────────────────────────────────────
    // 用户状态
    // ─────────────────────────────────────────────────────────

    /// @notice 每个地址存入的 ETH 抵押品，单位 wei
    mapping(address => uint256) public collateralETH;

    /// @notice 每个地址的 mUSD 债务，18 位精度。无利息，所以只在 borrow 时增长。
    mapping(address => uint256) public debt;

    // ─────────────────────────────────────────────────────────
    // 事件
    // ─────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 amount);

    /// @param priceUsed 借款当时 Oracle 的报价。
    ///        事后做实验分析时，靠这个字段就能还原「这笔债是在什么报价下批出来的」。
    event Borrow(address indexed user, uint256 amount, uint256 priceUsed);

    // ─────────────────────────────────────────────────────────

    /// @param stableToken mUSD 合约地址
    /// @param priceOracle 任何实现了 IPriceOracle 的合约
    constructor(address stableToken, address priceOracle) {
        stable = IERC20(stableToken);
        oracle = IPriceOracle(priceOracle);
    }

    /// @notice 向池子注入可供借出的 mUSD。部署后由部署者调用一次。
    /// @dev 调用前需要先 approve。资金一旦注入无法取出 —— 实验不需要这条路径。
    function fund(uint256 amount) external {
        stable.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice 存入 ETH 作为抵押品
    function depositETH() external payable {
        require(msg.value > 0, "No ETH");
        collateralETH[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // ─────────────────────────────────────────────────────────
    // 视图：全部依赖 oracle.getPrice()
    // ─────────────────────────────────────────────────────────

    /// @notice 抵押品按**当前** Oracle 报价折算的 mUSD 价值
    ///
    /// @dev 【单位换算，全项目唯一写法】
    ///      collateralETH 单位是 wei（1e18 = 1 ETH）
    ///      getPrice()   单位是 mUSD/ETH，18 位定点（2000e18 = 2000 mUSD per ETH）
    ///
    ///          1e18 wei × 2000e18 / 1e18 = 2000e18 mUSD   ✅
    ///
    ///      漏掉除 1e18 会大 1e18 倍；把乘除方向搞反会得到「每 mUSD 多少 ETH」。
    ///      守卫测试：LendingPool.t.sol → testCollateralValueUnitDirection
    function collateralValue(address user) public view returns (uint256) {
        return (collateralETH[user] * oracle.getPrice()) / 1e18;
    }

    /// @notice 按当前报价，该用户债务的**总上限**（不是「还能借多少」）
    /// @dev maxBorrow = 抵押品价值 / 1.5
    function maxBorrow(address user) public view returns (uint256) {
        return (collateralValue(user) * BPS_DENOM) / COLLATERAL_RATIO_BPS;
    }

    /// @notice 还能再借多少 = 上限 − 已借。已经超限时返回 0（不会下溢）。
    /// @dev 实验里「超额借款」这个指标 = 操纵后的本值 − 操纵前的本值。
    function availableToBorrow(address user) public view returns (uint256) {
        uint256 cap = maxBorrow(user);
        return cap > debt[user] ? cap - debt[user] : 0;
    }

    /// @notice 坏账规模：债务超出**当前**抵押能力的部分。
    ///
    /// @dev 这是攻击给协议造成的净损失。典型时序：
    ///          报价被推高 → 借满 → 攻击者平仓，报价回落 → badDebt > 0
    ///      注意它是按当前报价实时计算的，不是记账值。
    function badDebt(address user) public view returns (uint256) {
        uint256 cap = maxBorrow(user);
        return debt[user] > cap ? debt[user] - cap : 0;
    }

    // ─────────────────────────────────────────────────────────
    // 借款
    // ─────────────────────────────────────────────────────────

    /// @notice 借出 mUSD。唯一的风控检查就是「借完之后不超过 maxBorrow」。
    ///
    /// @dev 这里读取 price 只是为了写进事件；真正的检查在 maxBorrow() 内部
    ///      又读了一次 oracle。同一笔交易内两次读取必然一致，不存在竞态。
    ///
    ///      ⚠️ 没有重入保护。stable 是我们自己的 MiniUSD（标准 ERC-20，
    ///      transfer 不含回调），且状态更新在转账之前完成，符合
    ///      checks-effects-interactions。若有人把 stable 换成带 hook 的代币，
    ///      这里需要重新审计。
    function borrow(uint256 amount) external {
        require(amount > 0, "Zero amount");

        uint256 price = oracle.getPrice();

        require(debt[msg.sender] + amount <= maxBorrow(msg.sender), "Undercollateralized");

        debt[msg.sender] += amount;
        stable.safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount, price);
    }
}
