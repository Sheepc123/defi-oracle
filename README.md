# Mini DeFi Oracle 实验

用一个最小可用系统，量化比较 **Spot / TWAP / Aggregated** 三类预言机在价格操纵下的表现。

> 本文是**上手指南**，只讲怎么用。设计取舍的详细理由写在源码注释里，
> 实验设计与分工见 [`docs/DESIGN.md`](docs/DESIGN.md)。

---

## 环境配置 
1. Solidity

智能合约主要开发语言：Solidity

版本：^0.8.24

2. Foundry

安装：

curl -L https://getfoundry.sh/install | bash

3. Solidity 依赖

OpenZeppelin Contracts

OpenZeppelin 用于提供标准化、成熟的智能合约组件。

本项目主要使用：

ERC-20 Token

安装：

forge install OpenZeppelin/openzeppelin-contracts

推荐创建：

remappings.txt

并加入：

@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/


## 快速开始

```bash
cd mini-defi                                  # 必须在这一层，上一层没有 src/
git submodule update --init --recursive       # 首次克隆


# 
forge build
forge test -vv      #用于测试代码是否正确

forge test --match-test testSweepAllSizes -vv # 看攻击数据
```

环境：`forge 1.8.1` / `solc 0.8.36`。

---

## 文件架构

```
mini-defi/
├── README.md                      ← 本文
├── docs/DESIGN.md                 实验设计、分工、待实现的 Oracle 骨架
│
├── src/
│   ├── MiniUSD.sol                ERC-20 测试代币，总供应 1,000,000
│   ├── SimpleDEX.sol              恒定乘积 AMM，含 0.3% 手续费 + 价格累加器
│   ├── LendingPool.sol            150% 超额抵押借贷池，实验载体
│   └── interfaces/
│       └── IPriceOracle.sol       统一预言机接口
│
└── test/
    ├── MiniUSD.t.sol              1 个测试
    ├── SimpleDEX.t.sol            6 个测试
    ├── LendingPool.t.sol          14 个测试
    ├── base/
    │   ├── OracleScenario.sol     抽象实验骨架 ← A/B/C 从这里继承
    │   └── OracleScenario.t.sol   骨架自测（含最小 Spot 实现）
    └── mocks/
        └── MockSource.sol         可任意设价的假数据源
```

### 状态

| | 内容 |
| --- | --- |
| **已交付并冻结** | MiniUSD、SimpleDEX、LendingPool、IPriceOracle、OracleScenario |
| **待实现** | `SpotOracle`（A）、`TWAPOracle`（B）、`AggregatedOracle`（C）、结果汇总（D） |

前置依赖已经齐了，A/B/C 可以直接开工。

---

## 【必读】单位约定

**这是唯一不能出错的地方。**

```
getPrice() 返回：1 ETH 值多少 mUSD，18 位定点
  1 ETH = 2000 mUSD  →  2000e18
```

消费方一律这样写：

```solidity
uint256 valueInMUSD = ethAmount * oracle.getPrice() / 1e18;   // ✅
```

守卫测试：`LendingPool.t.sol::testCollateralValueUnitDirection`。

---

## 怎么写你的 Oracle

### 第一步：实现 IPriceOracle

```solidity
interface IPriceOracle {
    function getPrice() external view returns (uint256);       // mUSD/ETH, 18 位定点
    function description() external view returns (string memory);  // 会进结果表
}
```

`description()` 请写清参数，例如 `"TWAP (window=1800s)"`。

### 第二步：继承 OracleScenario，填三个 hook

[`test/base/OracleScenario.sol`](test/base/OracleScenario.sol) 把**攻击时序**和**指标计算**
全封死了，你只需要：

| hook | 职责 |
| --- | --- |
| `_deployOracle()` | 部署 DEX（可多个）+ Oracle，注入流动性 |
| `_manipulate(预算)` | 攻击者花 mUSD 推高报价，返回 `(实际花掉, 换到的 ETH)` |
| `_unwind()` | 把 ETH 全换回 mUSD，返回换回的数量 |
| `_warmUp()` | 可选。**TWAP 必须覆盖它**（预热窗口） |

可直接抄的最小实现：

```solidity
contract MyOracleTest is OracleScenario {
    SimpleDEX internal dex;
    uint256 internal heldETH;

    function _deployOracle() internal override returns (IPriceOracle) {
        dex = new SimpleDEX(address(token));
        token.approve(address(dex), TOTAL_TOKEN_DEPTH);
        dex.initializeLiquidity{value: TOTAL_ETH_DEPTH}(TOTAL_TOKEN_DEPTH);
        return new MyOracle(address(dex));
    }

    function _manipulate(uint256 budget)
        internal override returns (uint256 tokenSpent, uint256 ethGained)
    {
        token.approve(address(dex), budget);
        ethGained  = dex.swapTokenForETH(budget);
        heldETH    = ethGained;
        tokenSpent = budget;
    }

    function _unwind() internal override returns (uint256 tokenReturned) {
        tokenReturned = dex.swapETHForToken{value: heldETH}();
        heldETH = 0;
    }

    function testMyExperiment() public {
        Result memory r = runAttack(50_000e18);
        logResult(r);
        assertGt(r.netProfit, 0);
    }

    function testSweep() public { sweep(); }   // 四档规模全扫
}
```

完整可运行版本见 [`test/base/OracleScenario.t.sol`](test/base/OracleScenario.t.sol)。

**两条规矩**：覆盖 `setUp()` 必须先调 `super.setUp()`；**不要覆盖 `runAttack()`** ——
它是三组数字可比的唯一保证。

### 统一常量（不要在子类里改）

```
TOTAL_ETH_DEPTH   = 100 ether      全系统 ETH 深度预算
TOTAL_TOKEN_DEPTH = 200_000e18     全系统 mUSD 深度预算
REFERENCE_PRICE   = 2000e18        参考市场价
POOL_FUNDING      = 200_000e18     借贷池可借资金
ATTACKER_TOKEN_BUDGET = 500_000e18 攻击者预算
ATTACKER_COLLATERAL   = 10 ether   攻击者抵押品
attackSizes()     = [50k, 100k, 200k, 400k] mUSD
```

`setUp()` 末尾会断言 `oracle.getPrice() == REFERENCE_PRICE`。
如果你的 Oracle 在这里挂了，说明基线不是 2000 —— 先修这个再往下写。

---

## 核心指标

```
攻击净利 = 超额借出的 mUSD − 操纵 DEX 的往返损失
```

为正 = 该 Oracle 在该参数下**可被盈利攻击**。抵押品在两条路径里相同，相减时消掉了。

> ⚠️ **不要用「报价偏离了多少」当核心指标。** TWAP 在单区块操纵下的偏离必然是 0 ——
> 那是定义决定的，不是实验发现。

`Result` 的字段与结果表的列一一对应：
`priceBefore / priceAfter / deviationBps / tokenSpent / ethGained / tokenReturned /
attackCost / extraBorrow / netProfit / badDebt`。

---

## 给 B：价格累加器

TWAP 的数据来源只有一个 —— `dex.currentCumulativePrice()`，它是个 **view**，
会现场把「上次记账至今 × 当前价格」补算进去。**所以不必 poke DEX。**

```
TWAP(t0, t1) = (cumulative(t1) − cumulative(t0)) / (t1 − t0)
```

三条性质（都有测试守着，见 `SimpleDEX.t.sol`）：

1. 不需要驱动 DEX 记账，只存自己的观测点即可
2. **同一区块内的操纵不进累加器** —— 这是 TWAP 抗单块操纵的全部机制来源
3. 但攻击者**跨区块持有**被推高的价格时，累加器就开始记录它

第 3 条是你实验的核心：要测的是「把 TWAP 推到指定偏离度，需要跨多少区块、花多少手续费」，
而不是「单区块操纵后偏离了多少」。

参考骨架见 [`docs/DESIGN.md`](docs/DESIGN.md) §5.2。

---

## 给 C：多个 DEX 实例

`SimpleDEX` 支持任意多实例，不用改代码：

```solidity
SimpleDEX d = new SimpleDEX(address(token));
token.approve(address(d), 100_000e18);
d.initializeLiquidity{value: 50 ether}(100_000e18);   // 深度 50 ETH，价格 2000
```

**每个池的初始价都必须是 2000**（`tokenAmount / ethAmount == 2000`）。

**总深度预算 100 ETH / 200,000 mUSD 是全系统的**，不是每池的。
若三个池各 100 ETH，聚合版就凭空多了 3 倍流动性，「聚合更稳健」里会混进
「钱更多所以更难操纵」。建议拆成 **50 / 30 / 20 ETH**（不等权，观察攻击者是否挑最浅的池）。

主实验请用真实的多个 DEX，不要用三个 `MockSource` —— 那只能证明 `median()` 写对了。
`MockSource` 留给「单源返回 0 / 陈旧值 / 极端离群值」的降级测试。

参考骨架见 [`docs/DESIGN.md`](docs/DESIGN.md) §5.3。

---

## 三个 Foundry 坑

已经踩过了，都会给出**指向错误方向的报错**。

**① `vm.prank` 会被参数里的外部调用吃掉**

```solidity
vm.prank(alice);
pool.borrow(pool.maxBorrow(alice));   // ❌ prank 被 maxBorrow 消耗，borrow 变成 address(this)

uint256 cap = pool.maxBorrow(alice);  // ✅ 先落到局部变量
vm.prank(alice);
pool.borrow(cap);
```

报错是 `Undercollateralized`，完全指不到真正原因。在 `expectRevert` 下表现为
`next call did not revert as expected`。

**② 推进时间用 `_advance()`**，基类已提供。只 `vm.warp` 不 `vm.roll` 会造出
「同一区块但时间变了」的怪状态。

**③ 数组字面量首元素要显式转型**

```solidity
return [uint256(50_000e18), 100_000e18, ...];   // 否则推断成 uint80[4]
```

---

## 不要改这些文件

```
src/SimpleDEX.sol
src/LendingPool.sol
src/interfaces/IPriceOracle.sol
test/base/OracleScenario.sol
```

改 `IPriceOracle` 或 `OracleScenario` 会让所有人同时编译不过，务必先在组里说一声。
流程：组内同步 → 改 → `forge test` 全绿 → 通知其他人重新编译。

改动前先确认这 8 条不变量还成立，每条都有测试守着：

| 不变量 | 守卫测试 |
| --- | --- |
| 100 ETH / 200,000 mUSD → `getSpotPrice() == 2000e18` | `testInitialSpotPrice` |
| 买入再卖回必须亏 0.4%–0.8% | `testFeeIsCharged` |
| `k = ethReserve * tokenReserve` 单调不减 | `testKGrowsAfterSwap` |
| 落盘的 `priceCumulative` 只含**旧**价格 | `testCumulativeAccruesOldPriceNotNew` |
| 同一区块内 swap 不改变累计值 | `testCumulativeIgnoresIntraBlockSwap` |
| 1 ETH @ 2000e18 → `collateralValue` 恰好 2000e18 | `testCollateralValueUnitDirection` |
| 报价翻倍 → `maxBorrow` 严格翻倍 | `testMaxBorrowScalesWithOracle` |
| 攻击者 ETH 会计闭合 | `testAttackerEthAccountingIsClosed` |

第 4 条最隐蔽：把 `_accrue()` 从储备变更之前挪到之后，累加器就会记进被推高的新价格，
除了那个专门的测试，其它任何测试都发现不了。已用变异测试验证过它会报红。

---

## 当前状态

```
$ forge test
MiniUSDTest              1 passed
SimpleDEXTest            6 passed
LendingPoolTest         14 passed
OracleScenarioSelfTest   5 passed
                        26 passed, 0 failed
```

骨架自测跑出来的数据（最小 Spot 实现，非 A 的正式结果，单位 mUSD）：

| 攻击预算 | 操纵后报价 | 操纵成本 | 超额借款 | **攻击净利** |
| --- | --- | --- | --- | --- |
| 50,000 | 3,123 | 239 | 7,487 | **+7,247** |
| 100,000 | 4,495 | 400 | 16,636 | **+16,236** |
| 200,000 | 7,987 | 600 | 39,919 | **+39,319** |
| 400,000 | 17,963 | 802 | 106,426 | **+105,624** |

802 mUSD 的手续费换 10 万 mUSD 净利 —— Spot Oracle 在这套参数下是灾难性的。
手续费成本随规模亚线性增长（滑点主要由池深决定），超额借款近似线性，所以差距越拉越大。

### 待办

- **git 仓库零 commit**，`master` 是空分支。四人并行前必须先打基线提交
- **`docs/` 被 `.gitignore` 忽略**，`DESIGN.md` 提交不上去，别人拉不到
- **`forge fmt --check` 会红**（CI 里有这一步），需全量跑一次 `forge fmt` 或调整 CI

### 编译警告

`forge build` 的一批 lint 警告都核对过，无需修：`arbitrary-send-eth`、`block-timestamp`、
`divide-before-multiply`、`reentrancy-events`（SimpleDEX 的固有属性），
`locked-ether`（借贷池刻意没有赎回路径），`missing-events-access-control`（误报），
以及测试文件里的 `calls-loop` / `unused-return` / `unsafe-typecast`。


#####

先建立心智模型:代码分三层

第 1 层  src/          被攻击的「系统」——代币、交易所、借贷池
第 2 层  test/base/OracleScenario.sol    攻击「剧本」——谁在什么时候做什么
第 3 层  test/base/OracleScenario.t.sol  一次具体的「演出」——用哪个 Oracle、怎么下手
关键理解:攻击流程是写死在第 2 层的,三个人做三种 Oracle,但都跑同一套剧本。这样得出的数字才能横向比。第 3 层每个人写自己的,只填「具体怎么操纵」这一小块。

二、先跑起来
 
forge test --match-test testHarnessRunsEndToEnd -vv
-vv 是关键——不加它看不到任何 console2.log 输出,只会显示 PASS。输出:


[PASS] testHarnessRunsEndToEnd() (gas: 501419)
Logs:
  harness-spot (self-test only)
    token spent    (mUSD): 50000
    price before   (/ETH): 2000
    price after    (/ETH): 3123
    deviation       (bps): 5615
    attack cost    (mUSD): 239
    extra borrow   (mUSD): 7487
    NET PROFIT     (mUSD): 7247
    protocol bad debt    : 7471
这就是一次完整攻击的结果。

三、攻击代码在哪里
主流程:OracleScenario.sol:213 的 runAttack()
整个攻击就是这一个函数,五步,每步在代码里都有注释标号:

步骤	行号	做什么
1	L219	攻击者存 10 ETH 当抵押品,记下「诚实情况下能借多少」
2	L228	操纵 ← 调用 _manipulate()
3	L238	趁报价虚高,把能借的全借走
4	L246	平仓 ← 调用 _unwind(),报价掉回去
5	L251	算账
真正「动手」的两个地方
runAttack 只是剧本,具体怎么操纵是在第 3 层:

OracleScenario.t.sol:78 _manipulate() — 攻击者拿 50,000 mUSD 砸进 DEX 换 ETH:


token.approve(address(dex), tokenBudget);
ethGained = dex.swapTokenForETH(tokenBudget);   // ← 这一行就是攻击本身
为什么这样能推高价格?看 SimpleDEX.sol:59,价格的定义是 tokenReserve / ethReserve。你往池子里塞 mUSD、抽走 ETH,分子变大分母变小,价格自然涨。

OracleScenario.t.sol:92 _unwind() — 攻击者把 ETH 换回来,价格掉回去:


tokenReturned = dex.swapETHForToken{value: heldETH}();
四、结果在哪里
结果有两种形态:

① 结构体 Result — OracleScenario.sol:194。这是给代码用的,11 个字段,全精度。你在测试里这样拿:


Result memory r = runAttack(50_000e18);
assertGt(r.netProfit, 0);        // 断言攻击有利可图
② 打印输出 — logResult() 把结构体打到终端,给人看的。注意它把小数都截断了(/ 1e18),所以 7487 - 239 显示成 7247 而不是 7248——那是两次截断,不是 bug。要精确值就直接读结构体字段。

五、把这 8 个数字读懂
我用真实数据把整条链路串一遍,你可以自己验算:

起点:池子 100 ETH / 200,000 mUSD,价格 = 200000/100 = 2000。攻击者存 10 ETH 抵押。

抵押品值 10 × 2000 = 20,000 mUSD,抵押率 150%,所以诚实情况能借 20000/1.5 = 13,333。

第 2 步,操纵:砸 50,000 mUSD 进去。扣 0.3% 手续费后 49,850 参与定价,换出 19.95 ETH。

池子变成 80.05 ETH / 250,000 mUSD → 价格 = 3123。这就是 price after。
偏离 = (3123−2000)/2000 = 56.15% = 5615 bps。

第 3 步,借款:抵押品还是那 10 ETH,但池子说它值 31,230 了,于是能借 31230/1.5 = 20,820。

比诚实情况多借 20820 − 13333 = 7,487 ← 这就是 extra borrow。

第 4 步,平仓:19.95 ETH 换回来,拿到 49,761 mUSD。

投入 50,000 拿回 49,761,亏 239 ← 这就是 attack cost。这 239 全是手续费,如果 DEX 不收手续费,这个数字会是几乎 0,攻击就完全免费。

第 5 步,算账:


净利 = 多借到的 7,487 − 操纵花掉的 239 = 7,247   ← 攻击者赚了
平仓后池子是 100 ETH / 200,239 mUSD(手续费留在池里了),价格 2002.39,抵押品能撑的债务是 13,349。但攻击者欠了 20,820。


坏账 = 20,820 − 13,349 = 7,471   ← 协议亏了
一句话结论:花 239 mUSD 手续费,赚走 7,247 mUSD,协议吃 7,471 mUSD 坏账。这就是 Spot Oracle 的问题——它信任一个可以被单笔交易推动的价格。

六、你自己要写什么
如果你负责一个 Oracle,只需要三个文件动作:

1. 在 src/oracles/ 下写你的 Oracle,实现两个函数:


contract MyOracle is IPriceOracle {
    function getPrice() external view returns (uint256) { ... }
    function description() external view returns (string memory) { ... }
}
2. 在 test/ 下写测试,继承骨架,填三个 hook。直接抄 OracleScenario.t.sol:54-95 那一段,把 HarnessSpotOracle 换成你的。

3. 写你自己的 test 函数:


function testMyExperiment() public {
    Result memory r = runAttack(50_000e18);
    logResult(r);
}
不要碰 runAttack。 一旦改了,你的数字就和另外两个人不可比了。

七、几个实用命令

forge test                                  # 全跑,只看过没过
forge test -vv                              # ← 日常用这个,能看到 log
forge test --match-test testSweepAllSizes -vv   # 四档规模的完整数据表
forge test --match-contract LendingPoolTest -vv # 只跑借贷池
forge test --match-test testXxx -vvvv       # 出错时用,打印每一次合约调用
-vvvv 是调试利器。测试失败又看不懂时用它,会把整个调用栈铺出来,能看到具体哪次 swap 返回了什么。