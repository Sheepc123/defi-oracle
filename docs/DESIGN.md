# Mini DeFi Oracle 对比实验 — 设计文档

> 版本 v1.0 · 最后更新 2026-09-09
> 目标：用一个最小可用实验系统，量化比较 Spot / TWAP / Aggregated 三类 Oracle 在价格操纵下的表现。

---

## 1. 目标与边界

| 必须完成                         | 明确不做 |
| ---                        | --- |
| MiniUSD（ERC-20 测试代币）                | 完整 Uniswap / Aave |
| SimpleDEX（极简 AMM，含手续费与价格累加器） | 真实资金 / Mainnet 部署 |
| LendingPool（抵押 ETH、借 mUSD）           | Flash Loan、复杂清算系统 |
| SpotOracle / TWAPOracle / AggregatedOracle | 完整 Chainlink / Pyth 协议实现 |
| 统一 Foundry 测试与对比实验                  | 前端、数据库、后端微服务 |
| Pull Oracle / OEV 前沿调研                   | 自己实现 MEV/OEV 基础设施 |

**成功标准**：产出一张四列结果表（正常价格 / 攻击后价格 / 操纵成本 / 攻击净利），表中每个数字都能由一条 `forge test` 命令复现。

---

## 2. 五个关键设计决策

这五条是本文档相对最初设想的实质性调整，**每一条都直接决定实验结论是否成立**。

### D1 — SimpleDEX 必须收手续费（0.3%）

当前 AMM 没有任何手续费。在无手续费的恒定乘积池里，攻击者「大额买入 → 读价 → 卖回」一个来回除取整误差外不损失资金，**价格操纵是免费的**。而现实中 Uniswap 的 0.3% 手续费正是操纵成本的主要来源。

不加手续费，「操纵成本」这一列全是 0，三个 Oracle 会被无差别打穿，实验失去区分度。

### D2 — SimpleDEX 必须提供价格累加器

TWAP 的本质是价格对时间的积分，需要「价格 × 持续时间」的累计量。当前 DEX 没有 `lastUpdateTime` 也没有累加器，B 无法在不改 DEX 的前提下实现真正的 TWAP。

采用 Uniswap V2 的做法：在任何改变储备的函数开头调用 `_accrue()`，把**旧价格**按经过时间累加进 `priceCumulative`。同时提供 `currentCumulativePrice()` 视图函数，让 Oracle 无需 poke DEX 即可读到「截至当前区块」的累计值。

### D3 — 核心指标从「价格偏离度」改为「操纵成本」

**这是最重要的一条。** 如果只测「攻击后 Oracle 输出偏离了多少」，那么：

- TWAP 那一格必然接近 0 —— 单区块内的操纵 TWAP 根本观测不到，这是定义决定的，不是实验发现；
- Aggregated 那一格如果数据源是 `setPrice()` 的 mock，则「中位数抗单点异常」证明的只是 `median()` 写对了。

真正有信息量的量是：**达成同样的偏离度，攻击者需要付出多少成本**。因此每个实验都必须报告：

```
攻击净利 = 超额借出的 mUSD − 操纵往返的净损失
```

这个数为正，说明该 Oracle 在该参数下是可被盈利攻击的；为负，说明攻击不经济。这才是可以横向比较的结论。

### D4 — AggregatedOracle 的数据源用真实 DEX，不用纯 mock

C 部署 **3 个真实的 SimpleDEX 实例**（流动性深度不同），攻击者必须操纵其中 2 个才能移动中位数。得到的结论是「操纵成本随数据源数量的增长关系」，而不是数学恒等式。

保留 1 个 `MockSource`，专门用于测试「某个源返回 0 / 陈旧数据 / 极端离群值」时聚合器的降级行为。

### D5 — 公平性：聚合版的总流动性必须与单池版对齐

若单池版是 100 ETH 深度，聚合版 3 个池子不能各自 100 ETH —— 那等于凭空多了 3 倍流动性，「聚合更稳健」里混入了「钱更多所以更难操纵」。

约定：**所有场景的全系统总深度固定为 100 ETH / 200,000 mUSD**。聚合版按 50 / 30 / 20 ETH 拆分三个池（故意不等权，用于观察攻击者是否会挑最浅的池下手）。

---

## 3. 系统架构

```
                      Mini DeFi System

     ┌─────────────────────────────────────────────────┐
     │  共享基础层（Phase 0 冻结，A/B/C 不得修改）        │
     │                                                 │
     │   MiniUSD ────┐                                 │
     │               ├── SimpleDEX (fee + cumulative)  │
     │   ETH ────────┘        │                        │
     │                        │ getSpotPrice()         │
     │                        │ currentCumulativePrice()│
     │                        ▼                        │
     │                  IPriceOracle  ◄── 冻结接口      │
     │                        │                        │
     │                        ▼                        │
     │                   LendingPool                   │
     │              depositETH() / borrow()            │
     └─────────────────────────────────────────────────┘
                              ▲
              ┌───────────────┼───────────────┐
              │               │               │
        SpotOracle       TWAPOracle    AggregatedOracle
            (A)              (B)              (C)
                                          ├─ DEX_50
                                          ├─ DEX_30
                                          └─ DEX_20
                              │
                              ▼
                    OracleScenario 测试基类
                     （统一攻击脚本 + 指标计算）
                              │
                              ▼
                     Benchmark.t.sol → RESULTS.md
                              (D)
```

**关键约束**：三种 Oracle 只通过 `IPriceOracle` 接入 LendingPool。LendingPool 完全不知道自己接的是哪种 Oracle，这保证了实验条件一致。

---

## 4. 文件架构

见 [`../README.md`](../README.md#文件架构)。基础层已落地，以源码为准。

---

## 5. 待实现的 Oracle 骨架（A / B / C）

> 基础层（MiniUSD / SimpleDEX / LendingPool / IPriceOracle / OracleScenario）
> **已经交付并冻结**。用法见 [`../README.md`](../README.md)，细节以源码注释为准。
> 本节只保留还没有人实现的三个 Oracle 的参考骨架。
>
> 落地路径：`src/oracles/SpotOracle.sol` / `TWAPOracle.sol` / `AggregatedOracle.sol`。
> `MockSource` 已经在 `test/mocks/MockSource.sol` 提供，不需要重写。
>
> 下面的代码是**参考骨架，未编译验证**，请自行调试。

### 5.1 SpotOracle（A）

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SimpleDEX} from "../SimpleDEX.sol";

/// @notice 直接读取单个 DEX 的瞬时储备比 —— 实验中的「反面教材」基线
contract SpotOracle is IPriceOracle {
    SimpleDEX public immutable dex;

    constructor(address dexAddress) {
        dex = SimpleDEX(dexAddress);
    }

    function getPrice() external view returns (uint256) {
        return dex.getSpotPrice();
    }

    function description() external pure returns (string memory) {
        return "Spot (single DEX)";
    }
}
```

### 5.2 TWAPOracle（B）

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SimpleDEX} from "../SimpleDEX.sol";

/// @notice 基于 DEX 价格累加器的时间加权平均价
contract TWAPOracle is IPriceOracle {
    SimpleDEX public immutable dex;

    /// @notice 目标平均窗口（秒）
    uint256 public immutable window;

    struct Observation {
        uint256 timestamp;
        uint256 cumulative;
    }

    Observation[] public observations;

    constructor(address dexAddress, uint256 windowSeconds) {
        require(windowSeconds > 0, "Zero window");
        dex = SimpleDEX(dexAddress);
        window = windowSeconds;
        _record(); // 起始观测点
    }

    /// @notice 任何人可调用，记录一个观测点。真实场景由 keeper / 套利者驱动。
    function update() external {
        _record();
    }

    function _record() internal {
        (uint256 cumulative, uint256 timestamp) = dex.currentCumulativePrice();
        observations.push(Observation(timestamp, cumulative));
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    function getPrice() external view returns (uint256) {
        require(observations.length > 0, "No observations");

        (uint256 cumNow, uint256 tNow) = dex.currentCumulativePrice();
        uint256 target = tNow > window ? tNow - window : 0;

        // 从新到旧，找第一个「至少和窗口一样老」的观测点
        Observation memory anchor = observations[0];
        for (uint256 i = observations.length; i > 0; i--) {
            if (observations[i - 1].timestamp <= target) {
                anchor = observations[i - 1];
                break;
            }
        }

        uint256 elapsed = tNow - anchor.timestamp;
        require(elapsed > 0, "Window not warmed up");

        return (cumNow - anchor.cumulative) / elapsed;
    }

    function description() external view returns (string memory) {
        return string.concat("TWAP (window=", _toString(window), "s)");
    }

    function _toString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        for (uint256 t = v; t != 0; t /= 10) digits++;
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
```

> **B 需要做的一个设计判断**：当没有足够老的观测点时（历史短于 window），上面的实现会退化为「用现有最老的观测点」，即返回一个比请求窗口更短的平均值。另一种选择是直接 revert。**两种都要在报告里写清楚，并测试各自后果** —— 这正是真实 Oracle 部署初期的已知风险点。

### 5.3 AggregatedOracle（C）

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice 取多个数据源的中位数
contract AggregatedOracle is IPriceOracle {
    IPriceOracle[] public sources;

    constructor(IPriceOracle[] memory initialSources) {
        require(initialSources.length >= 3, "Need >= 3 sources");
        for (uint256 i = 0; i < initialSources.length; i++) {
            sources.push(initialSources[i]);
        }
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function getPrice() external view returns (uint256) {
        uint256 n = sources.length;
        uint256[] memory prices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            prices[i] = sources[i].getPrice();
        }
        return _median(prices);
    }

    /// @dev 插入排序后取中位数。n 很小（3~5），O(n²) 无所谓。
    function _median(uint256[] memory a) internal pure returns (uint256) {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; i++) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
        return n % 2 == 1 ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2;
    }

    function description() external view returns (string memory) {
        return "Aggregated (median)";
    }
}
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

/// @notice 可任意设定报价的数据源，用于测试聚合器的降级行为（返回 0 / 离群值 / 陈旧值）
contract MockSource is IPriceOracle {
    uint256 public price;
    string private label;

    constructor(uint256 initialPrice, string memory sourceLabel) {
        price = initialPrice;
        label = sourceLabel;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }

    function description() external view returns (string memory) {
        return label;
    }
}
```

---

## 6. 实验设计

### 6.1 Phase 0 必须通过的正确性测试

这几个测试保护共享基础层，**A/B/C 开工前必须全绿** （已完成）：

| 测试 | 断言 | 为什么重要 |
| --- | --- | --- |
| `testInitialSpotPrice` | 100 ETH / 200k mUSD → 2000e18 | 基线锚点 |
| `testFeeIsCharged` | 立刻 swap 回来会亏损 ≈ 0.6% | D1 生效，否则操纵免费 |
| `testKGrowsAfterSwap` | `ethReserve*tokenReserve` 单调不减 | 手续费确实留在池内 |
| `testCumulativeAccruesOldPrice` | warp 1h 不交易 → 累计增量 = 2000e18 × 3600 | **`_accrue()` 位置正确**，最易错 |
| `testCumulativeIgnoresIntraBlockSwap` | 同一区块内 swap 后累计值不变 | TWAP 抗单块操纵的机制基础 |
| `testMaxBorrowTracksOracle` | 报价翻倍 → `maxBorrow` 翻倍 | 传导路径打通 |

`testCumulativeAccruesOldPrice` 是重点：如果 `_accrue()` 被误放在储备变更**之后**，累加器会记录新价格，TWAP 的抗操纵性看起来比实际差，而普通单元测试发现不了。

### 6.2 攻击场景（三种 Oracle 完全一致）

```
t=0    部署，DEX 价格 = 参考价 = 2000 mUSD/ETH
       攻击者抵押 10 ETH，记录 availableToBorrow = B0
       （TWAP 场景：额外预热 window 时长，每 60s 调一次 update()）

t=T    攻击者用 X mUSD 大额 swapTokenForETH
       → tokenReserve↑ / ethReserve↓ → 报价被推高
       读取三个量：
         P_after       = oracle.getPrice()
         B1            = availableToBorrow(attacker)
         extraBorrow   = B1 - B0

t=T+1  攻击者把换得的 ETH 全部 swap 回 mUSD（平仓）
       attackCost = X - 换回的 mUSD          ← 手续费 + 滑点的净损失

       netProfit  = extraBorrow - attackCost
```

X 取 `{50k, 100k, 200k, 400k}` mUSD 四档，形成曲线而非单点。

### 6.3 各 Oracle 的专属变量

| 负责人 | 扫描维度 | 预期观察 |
| --- | --- | --- |
| A | 攻击规模 X（4 档） | 偏离度随 X 单调增；`netProfit` 在某个 X 处转正 |
| B | 窗口 `{60s, 600s, 1800s, 3600s}` × X | 偏离度随窗口增大而衰减；同时记录**报价追踪真实价格变动的延迟** |
| C | 源数量 `{1, 3, 5}`、攻击 1 个池 vs 攻击 2 个池 | 攻 1 池对中位数无影响；攻 2 池成本远高于单池 |

**B 必须同时报告延迟成本**：窗口越长越抗操纵，但真实价格变动时 Oracle 跟不上。做法是让 DEX 价格阶跃到 2400，然后测量 TWAP 报价爬到 2400 的 95% 需要多久。只报抗操纵性、不报延迟，是不完整的结论。

**C 的关键实验是「攻最浅的池」**：3 个池深度 50/30/20 ETH，攻击者要移动中位数就必须拿下 20 和 30 这两个浅池。对比「攻单个 100 ETH 池」的成本，这个差值就是聚合带来的真实安全收益。

### 6.4 最终结果表（D 产出 `RESULTS.md`）

| Oracle | 正常价格 | 攻击后价格 | 偏离 (bps) | 操纵成本 (mUSD) | 超额借款 (mUSD) | 攻击净利 | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Spot | 2000 | ? | ? | ? | ? | ? | |
| TWAP-600s | 2000 | ? | ? | ? | ? | ? | |
| TWAP-3600s | 2000 | ? | ? | ? | ? | ? | |
| Aggregated-3 | 2000 | ? | ? | ? | ? | ? | |

每一行都必须能由一条 `forge test --mt <testName> -vv` 复现，命令写进表格脚注。

---

## 7. 分工与排期

### Phase 0 — 共享基础层 ✅ 已完成

下表保留作记录。实际交付含 26 个测试与 2 轮变异验证，见 README。

**这是硬前置：Phase 0 不冻结，A/B/C 无法并行。** 四人一起做，2–3 天。

| 任务 | 建议责任人 | 工作量 |
| --- | --- | --- |
| git 初始化：首次 commit、`.gitignore` 校验、submodule 说明写进 README | D | 0.5h |
| 删掉根目录多余的 `remappings.txt`（在 `mini-defi/` 外，Forge 读不到） | D | 5min |
| `forge fmt` 全量跑一遍（当前 CI 的 `fmt --check` 一 push 就会红） | D | 0.5h |
| `IPriceOracle.sol` 接口定稿并冻结 | 全员评审 | 0.5h |
| `SimpleDEX.sol` 加 fee + 累加器 | B（TWAP 最依赖它） | 2h |
| `SimpleDEX.t.sol` 补 6.1 的正确性测试 | A | 1.5h |
| `LendingPool.sol` + 测试 | C | 2.5h |
| `OracleScenario.t.sol` 抽象基类 | D | 3h |

Phase 0 合计约 **10.5 人时**。产出物打 tag `phase0-frozen`，之后任何对 `src/SimpleDEX.sol`、`src/LendingPool.sol`、`src/interfaces/` 的修改都必须四人同意。

### Phase 1 — 并行开发（4–5 天）

| 成员 | 交付物 | 需要掌握 | 难度 | 工作量 |
| --- | --- | --- | --- | --- |
| **A** | `SpotOracle.sol` + `SpotOracle.t.sol`；攻击规模扫描曲线；解释单池瞬时价格的风险来源 | AMM 储备、瞬时价格、Foundry `snapshotState` | ★★☆☆☆ | 4–5h |
| **B** | `TWAPOracle.sol` + `TWAPOracle.t.sol`；4 个窗口 × 4 个攻击规模；**抗操纵 / 延迟权衡曲线** | 累加器语义、`vm.warp` + `vm.roll`、时间加权平均 | ★★★★☆ | 7–9h |
| **C** | `AggregatedOracle.sol` + `MockSource.sol` + 测试；3 池不等深度攻击实验；单源异常降级测试 | 多源聚合、median、深度与滑点关系 | ★★★☆☆ | 6–7h |
| **D** | `Benchmark.t.sol`（把 A/B/C 的 Oracle 装进同一张表）；前沿调研笔记 | Push/Pull、freshness、latency、OEV | ★★★☆☆ | 4–5h |

> **相比初版分工表的调整**：B 的难度从 ★★★ 上调到 ★★★★（累加器语义 + 延迟维度是全项目最难的部分）；D 的编程量从 ★☆☆☆☆ 上调到 ★★★☆☆（`OracleScenario` 和 `Benchmark` 都是集成活，不是纯写文档）。

### Phase 2 — 汇总与报告（2–3 天）

| 任务 | 责任人 | 工作量 |
| --- | --- | --- |
| `RESULTS.md` 统一结果表 + 复现命令 | D | 2h |
| 前沿调研：Pull Oracle 模型、Pyth、Chainlink Data Streams、OEV/MEV 与 Future Work | D | 3–4h |
| 交叉复核：每人跑一遍别人的测试，确认数字可复现 | 全员 | 各 1h |
| 最终报告整合 | 全员 | 3h |

**总量约 34–40 人时**，四人分摊每人 9–10 小时。

### D 的调研清单（Phase 2）

不写代码，产出一份 2–3 页笔记，回答四个问题：

1. **Push vs Pull**：本项目三种 Oracle 都是 push 模型（链上主动读）。Pyth 的 pull 模型把更新成本转移给使用者，带来了什么新的攻击面？
2. **Freshness / staleness**：Chainlink 的 heartbeat + deviation threshold 机制，与本项目 TWAP 的窗口选择在权衡上有什么共同点？
3. **Chainlink Data Streams**：低延迟报价如何避免重新引入 spot 的脆弱性？
4. **OEV**：预言机更新本身可被抢跑套利，这部分价值目前流向谁？有哪些回收方案（如 API3 的 OEV Network）？

---

## 8. 已知风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| Phase 0 拖延，A/B/C 空转 | 最高 | Phase 0 打包成一次 PR，全员评审后 tag 冻结，不做增量交付 |
| 多人同时改 `SimpleDEX.sol` | 高 | Phase 1 起该文件锁定；需要改动必须先在群里同步 |
| `_accrue()` 位置写错 | 高（TWAP 结论失真） | 6.1 的 `testCumulativeAccruesOldPrice` 专门守这一点 |
| 单位方向搞反（mUSD/ETH vs ETH/mUSD） | 中 | 接口注释钉死；所有消费方统一写 `x * price / 1e18` |
| `block.timestamp` 在 Foundry 里起始为 1，TWAP 首次读取 `elapsed == 0` | 中 | 构造函数记录起始观测；`getPrice()` 有 `elapsed > 0` 检查；测试里先 `vm.warp(1000)` |
| 只 `warp` 不 `roll`，出现「同区块但时间变了」 | 低 | 基类提供 `_advance(uint256 seconds)` 同时推进两者 |
| CI `forge fmt --check` 与手写换行风格冲突 | 低 | Phase 0 全量 `forge fmt` 一次，之后加 pre-commit |

---

## 9. 一句话总结

**Phase 0 冻结共享层 → A/B/C 并行做三个 Oracle → D 汇总成一张以「攻击成本」为核心指标的表。**

三条不能妥协的红线：DEX 必须收手续费（否则操纵免费）、TWAP 必须基于累加器（否则不是真 TWAP）、聚合器必须用真实多池且总深度对齐（否则结论是同义反复）。
