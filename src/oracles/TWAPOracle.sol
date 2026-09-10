// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SimpleDEX} from "../SimpleDEX.sol";

/**
 * @title TWAPOracle
 * @notice 基于 SimpleDEX 价格累加器的时间加权平均价格预言机
 * @dev 参考 Uniswap V2 TWAP 设计。
 *
 * 核心机制：
 * - update() 把当前的累加器值和时间戳追加到 observations[] 末尾。
 * - getPrice() 回溯到 timestamp <= (now − window) 的最近观测点，
 *   用 (当前累加值 − 该点累加值) / (当前时间 − 该点时间) 求平均价。
 *
 * ⚠️ 与 Uniswap V2 的差异（教学简化，答辩时会被问）：
 * - V2 用固定长度的**环形槽位**存储观测点，写入成本 O(1)，gas 恒定。
 * - 本实现用**只增不减的动态数组**：update() 每调用一次就 push 一次，
 *   gas 随观测点数量单调上升，长期运行会越来越贵。
 *   实验窗口最长 3600s、预热步长 60s，最多约 60 个观测点，成本可接受。
 *   生产环境必须换成环形缓冲。
 */
contract TWAPOracle is IPriceOracle {
    // ── 不可变状态 ──────────────────────────────────────────
    SimpleDEX public immutable dex;
    uint256 public immutable window; // 时间窗口（秒）

    // ── 观测点存储（数组） ──────────────────────────────
    struct Observation {
        uint256 cumulativePrice;
        uint256 timestamp;
    }
    Observation[] public observations;

    // ── 事件 ──────────────────────────────────────────────
    event ObservationUpdated(uint256 cumulativePrice, uint256 timestamp);

    // ── 构造函数 ──────────────────────────────────────────
    constructor(address _dex, uint256 _window) {
        require(_window > 0, "TWAPOracle: zero window");
        dex = SimpleDEX(_dex);
        window = _window;

        // 初始化：记录第一个观测点
        (uint256 initialCumulative, uint256 initialTime) = dex.currentCumulativePrice();
        observations.push(Observation({
            cumulativePrice: initialCumulative,
            timestamp: initialTime
        }));
        emit ObservationUpdated(initialCumulative, initialTime);
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @notice 当前 getPrice() 实际回溯的时间跨度（秒）。
    /// @dev 窗口未预热时这个值小于 `window` —— 此时抗操纵性弱于标称值。
    ///      实验分析时用它判断某一格数据是否已经「预热充分」。
    function elapsedWindow() external view returns (uint256) {
        (, uint256 currentTime) = dex.currentCumulativePrice();
        uint256 span = currentTime - observations[0].timestamp;
        return span > window ? window : span;
    }

    // ── 核心功能 ──────────────────────────────────────────

    /**
     * @dev 更新观测点：将当前累加器值和时间戳追加到数组末尾。
     *      任何人都可以调用，建议由 keeper 或前端定时触发。
     */
    function update() external {
        (uint256 currentCumulative, uint256 currentTime) = dex.currentCumulativePrice();

        // 避免重复记录相同时间戳的观测点
        uint256 lastIdx = observations.length - 1;
        if (observations[lastIdx].timestamp == currentTime) {
            return;
        }
        observations.push(Observation({
            cumulativePrice: currentCumulative,
            timestamp: currentTime
        }));
        emit ObservationUpdated(currentCumulative, currentTime);
    }

    /**
     * @dev 实现 IPriceOracle 的 getPrice 接口
     * @return price 1 ETH = X mUSD，精度 1e18
     */
    function getPrice() external view returns (uint256) {
        (uint256 currentCumulative, uint256 currentTime) = dex.currentCumulativePrice();

        // 链上历史比窗口还短时避免下溢，钳到 0
        uint256 targetTime = currentTime > window ? currentTime - window : 0;

        // 从新到旧，找第一个「至少和窗口一样老」的观测点。
        // 找不到 → targetIndex 保持 0，即用最老的观测点：
        // 此时实际回溯跨度短于名义窗口，抗操纵性弱于标称值（窗口未预热）。
        uint256 targetIndex = 0;
        for (uint256 i = observations.length; i > 0; i--) {
            if (observations[i - 1].timestamp <= targetTime) {
                targetIndex = i - 1;
                break;
            }
        }

        Observation memory targetObs = observations[targetIndex];

        uint256 deltaTime = currentTime - targetObs.timestamp;
        require(deltaTime > 0, "TWAPOracle: zero time elapsed");

        uint256 deltaCumulative = currentCumulative - targetObs.cumulativePrice;
        return deltaCumulative / deltaTime;
    }

    /**
     * @dev 实现 IPriceOracle 的 description 接口
     */
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
