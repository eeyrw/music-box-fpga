# Vivado 综合策略研究与实现报告查验

本文记录 Smart Artix `smart_artix_top` 在 Vivado 2025.2 下的综合与
implementation 策略选择、对照实验和报告查验方法。目标器件是
`xc7a50tfgg484-2`，当前配置为 512 voices、8 个 work entries、8 个 job
entries、最大 16 frames，系统逻辑运行在 MIG `ui_clk` 的 100 MHz 时钟域。

本文不是 Vivado 选项大全。策略必须结合器件系列、资源压力、关键路径形态
和完整 post-route 结果选择；不能因为某个选项名称含有 `Performance` 或
`Aggressive` 就默认它更好。

## 结论

当前默认配置为：

```text
Synthesis:     Flow_PerfOptimized_high
Implementation: Performance_ExplorePostRoutePhysOpt
Parallel jobs: 4
```

选择理由：

- 当前设计的主要风险是 100 MHz setup 裕量和 LUT 压力，不是 DSP、BRAM
  或寄存器容量。
- `Flow_PerfOptimized_high` 以更多 LUT/寄存器自由度换取更低逻辑层级；当前
  仍能装入器件，但 LUT 已达到约 78.6%，因此不能继续盲目叠加面积开销。
- `Performance_ExplorePostRoutePhysOpt` 对当前综合网表得到 `WNS +0.047 ns`；
  对照的 `Performance_ExploreWithRemap` 经 post-route phys-opt 后只有
  `WNS +0.019 ns`，运行时间也更长。
- `ExploreWithRemap` 的 post-place 估算更好，但 route 结果更差。这个实验
  证明 post-place WNS 不能替代 post-route signoff。
- 不默认强制 global retiming。AMD 文档说明非 Versal 器件在 `auto` 下不执行
  global retiming；在包含 MIG、Clocking Wizard 和多个控制边界的顶层强开
  retiming，必须作为单独实验验证。
- 显式关闭自动增量综合。`vivado-synth` 本来就要求新鲜综合网表；
  `vivado-impl` 应复用已完成且未过期的 synthesis，而不是维护一个会反复
  触发相同综合的 reference DCP。

这里的 setup 裕量很小。当前结果是“满足现有约束”，不是对后续 RTL 修改
或板级外部时序的永久保证。

## 综合选项研究

### 预定义策略优先于零散开关

UG901 将 synthesis strategy 定义为一组相互配合的参数。当前
`Flow_PerfOptimized_high` 在实际日志中展开为：

```text
synth_design
  -directive PerformanceOptimized
  -fsm_extraction one_hot
  -keep_equivalent_registers
  -resource_sharing off
  -no_lc
  -shreg_min_size 5
```

这些开关的组合含义是：

- `PerformanceOptimized`：优先减少逻辑层级，可能增加面积。
- `fsm_extraction one_hot`：用更多寄存器换取较浅状态译码。对小型高速 FSM
  常有利，但大型低速 FSM 不一定适合。
- `keep_equivalent_registers`：允许后续放置使用等价寄存器副本改善扇出和
  物理位置，代价是 FF 数量可能上升。
- `resource_sharing off`：不强行共享算术资源，减少共享 mux 和长控制路径，
  代价是 LUT/DSP 可能增加。
- `no_lc`：不主动做 LUT combining，减少过度打包对时序和可布线性的影响。
- `shreg_min_size 5`：只有较长移位链才推断 SRL，保留短寄存器链供物理优化。

### 其他综合策略何时使用

| 策略 | 主要目标 | 本设计中的使用条件 |
| --- | --- | --- |
| Vivado Synthesis Defaults | 运行时间与 QoR 平衡 | 建立基线，或 Performance 策略面积过高时 |
| `Flow_PerfOptimized_high` | 降低逻辑层级，提高时序性能 | 当前默认；每次必须检查 LUT/FF 增量 |
| `Flow_AlternateRoutability` | 减少不利于 routing 的 MUXF/CARRY 结构 | route 拥塞或长 carry/mux 路径成为主因时对照 |
| `Flow_AreaOptimized_high` | 减少面积 | LUT 无法装入时尝试，但可能损失时序和改变 RAM/DSP 映射 |
| `Flow_RuntimeOptimized` | 缩短编译时间 | 早期语法/资源估算；不能用于 signoff |

不要把所有优化同时打开。面积优化、资源共享、logic compaction 与性能优化
存在直接权衡；随意叠加也会让结果无法归因。

### hierarchy、retiming 和资源推断

- `flatten_hierarchy rebuilt` 是常规折中：允许跨层级优化，同时重建接近 RTL
  的层级以便报告定位。`full` 会增加调试难度，`none` 会限制跨层级优化。
- Global retiming 必须检查 CDC、异步复位、RAM/DSP 边界和协议延迟。它保持
  同步行为，但不代表所有带异步控制或跨时钟结构都适合移动寄存器。
- 当前综合日志提示若干 BRAM 没有可吸收的输出寄存器，以及
  `block_interleaved_voice_dsp.sv` 的宽乘法器后流水级不足。这些是 RTL
  候选优化点，不能靠 strategy 永久掩盖。
- RAM/DSP 推断结果是硬门槛。策略对照必须确认大数组仍映射到 BRAM、乘法和
  MAC 仍按预期映射到 DSP48E1；不能只比较 WNS。

## Implementation 策略研究

Implementation 不是单一“综合”步骤，而是以下链路：

```text
opt_design
  -> place_design
  -> phys_opt_design
  -> route_design
  -> phys_opt_design (Post-Route, optional)
```

UG904 中适合 7-series 的主要策略如下：

| 策略 | 特点 | 使用判断 |
| --- | --- | --- |
| Vivado Implementation Defaults | 默认平衡 | 第一条基线 |
| `Performance_Explore` | 各阶段使用 Explore 增加搜索 | 普通时序收敛实验 |
| `Performance_ExplorePostRoutePhysOpt` | Explore，并在 route 后再做物理优化 | 当前默认；适合小幅负裕量或边缘正裕量 |
| `Performance_ExploreWithRemap` | `opt_design` 做逻辑 remap，route 使用更严格时序策略 | 逻辑层级过深时对照；必须完整 route |
| `Performance_NetDelay_high/low` | 对长距离和高扇出网络提高 delay cost | 布线延迟而非逻辑延迟主导时 |
| `Performance_Retiming` | 物理 retiming 与额外放置优化 | 可移动流水级且协议延迟允许时单独验证 |
| `Congestion_SpreadLogic_medium/high` | 扩散逻辑以缓解局部拥塞 | congestion report 明确出现较高 level 窗口时 |
| `Area_Explore*` | 减少 LUT/寄存器 | 容量优先且时序有余量时 |
| `Flow_Quick` | 关闭时序驱动以换速度 | 仅做快速资源估算 |

`AggressiveExplore` 不应作为无条件默认。官方文档明确指出它会显著增加运行
时间；如果当前问题是 RTL 逻辑深度、未流水化 RAM/DSP 或错误约束，更高搜索
强度不会修复根因。

### post-route phys-opt 必须真正执行

仅设置 `Performance_ExplorePostRoutePhysOpt` 不够。Project mode 的
`launch_runs -to_step route_design` 会在额外物理优化前停止。脚本现在读取
`STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED`，并在启用时把目标步骤设为：

```tcl
launch_runs $impl_run_name -to_step {phys_opt_design (Post-Route)}
```

注意内部属性名与 `launch_runs` 接受的显示名称不同。

## 2026-07-30 对照实验

两轮实验使用相同 Vivado 2025.2、相同 RTL、相同约束、相同
`Flow_PerfOptimized_high` 综合网表和相同并行度，仅改变 implementation
strategy。

| 指标 | Explore + post-route phys-opt | ExploreWithRemap |
| --- | ---: | ---: |
| 最终 WNS | +0.047 ns | +0.019 ns |
| 最终 TNS | 0.000 ns | 0.000 ns |
| 最终 WHS | +0.053 ns | +0.056 ns |
| 最终 THS | 0.000 ns | 0.000 ns |
| 最差 setup logic levels | 14 | 15 |
| Slice LUTs | 25,633 (78.63%) | 25,639 (78.65%) |
| Slice registers | 26,874 (41.22%) | 26,807 (41.12%) |
| BRAM tiles | 50 (66.67%) | 50 (66.67%) |
| DSP48E1 | 39 (32.50%) | 39 (32.50%) |
| Routing errors | 0 | 0 |

`ExploreWithRemap` 在 `opt_design` 中创建 2608 个 cell、删除 2570 个 cell；
post-place WNS 为 `+0.231 ns`，优于另一策略的 `+0.162 ns`。但是第一次 route
结束时 WNS 为 `-0.026 ns`，最后依靠 post-route phys-opt 修到 `+0.019 ns`。
默认策略 route 后直接得到 `+0.047 ns`，post-route phys-opt 因已满足 setup 而
没有修改网表。综合考虑裕量和运行时间，保留默认策略。

这不是跨版本的永久排名。Vivado 版本、RTL、约束、器件或 seed 改变后，应
重新对照。

## 报告查验顺序

### 1. 确认运行身份和新鲜度

先检查 `post_route_summary.json`：

- `vivado_version`、`part`、`top` 是否正确；
- `synth_strategy`、`impl_strategy` 是否与命令一致；
- voice/work/job/frame 参数是否来自预期 Makefile 配置；
- run 是否因输入变化标记 `NEEDS_REFRESH`；
- 实际日志中是否出现预期的 directive 和 post-route step。

`project.tcl` 只在 defines、top、源集合或策略实际变化时更新并保存项目。
相同配置下重复执行 `make vivado-impl`，日志应明确显示 synthesis 和
implementation 均为 `complete and up-to-date`；否则应先定位是哪项输入使 run
过期，而不是直接接受一次无法归因的重复综合。

资源或策略对照使用：

```bash
VIVADO_FORCE_REBUILD=1 make vivado-impl
make vivado-impl VIVADO_SYNTH_STRATEGY=Flow_AlternateRoutability \
  VIVADO_IMPL_STRATEGY=Performance_ExploreWithRemap
```

### 2. 检查 routing 完整性和 DRC

先于 timing 检查：

- `post_route_route_status.rpt` 中 fully routed nets 必须等于 routable nets；
- unrouted、partially routed、routing errors 和 node overlaps 必须为 0；
- `post_route_drc.rpt` 中 Error 和 Critical Warning 必须为 0；
- Warning 必须分类审查，不能因为 bitstream 能生成就整体忽略。

当前推荐策略结果为 48,436 / 48,436 fully routed nets，routing errors 为 0。

### 3. 检查 setup、hold 和 pulse width

`post_route_timing.rpt` 是主入口：

- WNS >= 0 且 TNS = 0；
- setup failing endpoints = 0；
- WHS >= 0 且 THS = 0；
- hold failing endpoints = 0；
- WPWS/TPWS 和 pulse-width failing endpoints 也必须检查；
- 每个 clock/path group 都要检查，不能只看总表。

然后读：

- `post_route_setup_paths.rpt`：确认最差路径的起点、终点、clock、逻辑层级和
  datapath delay；
- `post_route_hold_paths.rpt`：确认 hold 修复没有制造新的短路径问题；
- `post_route_clock_interaction.rpt`：检查跨时钟关系是否按预期约束或异步分组。

当前最差 setup 路径位于 renderer descriptor plan 到 descriptor BRAM 写口，
logic levels 为 14，datapath delay 为 9.446 ns。它是后续 RTL 优化的首要候选，
但本次已满足 100 MHz 约束。

### 4. 检查约束覆盖

`post_route_check_timing.rpt` 当前结果：

- no clock: 0；
- constant clock: 0；
- unconstrained internal endpoints: 0；
- multiple clock: 0；
- timing loops: 0；
- 9 个输入端口缺少 input delay；
- 13 个输出端口缺少 output delay。

内部同步逻辑已覆盖，但 SPI、SD、I2S、reset 和状态输出的外部时序仍不完整。
因此当前结果不能作为板级 I/O signoff。外部 delay 必须来自真实 MCU、SD 卡、
codec 和 PCB 时序，而不能为消除 warning 随意填写。

### 5. 检查资源和层级归属

`post_route_utilization.rpt` 检查器件总量，
`post_route_utilization_hier_depth4.rpt` 检查资源归属。当前结果：

```text
Slice LUTs       25,633 / 32,600  78.63%
Slice Registers  26,874 / 65,200  41.22%
Block RAM tiles      50 / 75      66.67%
DSP48E1              39 / 120     32.50%
```

QoR assessment 给出 score 5，但把 LUT 超过 70% 标为 REVIEW。Score 5 不是容量
豁免；LUT 继续增长会同时压缩 routing 和时序余量。

### 6. 检查 QoR、methodology 和 congestion

- `post_route_qor_assessment.rpt`：按 utilization、netlist、clocking、
  congestion、timing、constraints 分类检查。阈值是风险提示，不是器件硬限制。
- `post_route_qor_suggestions.rpt`：用于发现可应用的 cell/clock/congestion
  建议。Vivado 2025.2 的 ML strategy prediction 不支持 7-series，不能把
  UltraScale/Versal 的自动策略流程套到 Artix-7。
- `post_route_methodology.rpt`：当前包含 async-reset LUT、同步寄存器链放置、
  BRAM 输出寄存器和 XDC 查询效率等 warning，应按 ID 分类处理或记录 waiver。
- `post_route_congestion.rpt`：当前没有 level 5 以上 congestion window；这与
  QoR congestion status OK 一致，因此不应先上 `SpreadLogic_high`。
- `post_route_high_fanout.rpt`：检查 reset、enable、valid、voice/work ID 等控制
  网。只有真实高扇出路径主导 delay 时才选择 fanout/net-delay 策略。

当前 DRC 仍有 warning，主要包括 DSP 输入/输出流水建议、BRAM 异步控制检查、
clock buffer 连接以及缺少 `CFGBVS`/`CONFIG_VOLTAGE`。其中器件配置电压和外部
I/O 约束属于板级 signoff 项；DSP/BRAM pipeline 建议属于 RTL 时序优化候选。
本次推荐策略的 JSON 汇总记录 127 条 DRC warning、0 Error 和 0 Critical
Warning。127 不是“通过”或“失败”的单一判据，必须回到 `post_route_drc.rpt`
按检查 ID 和层级逐类处置。

## Signoff 门槛

一次实现只有同时满足以下条件才可作为当前约束下的通过结果：

1. Synthesis 和 implementation 均无 Error/Critical Warning。
2. 所有 routable nets 完全布线，routing errors 为 0。
3. Setup、hold、pulse width 均无 failing endpoint。
4. 无 unconstrained internal endpoint、timing loop 或无时钟寄存器。
5. LUT、FF、BRAM、DSP 和 clocking 资源均未超限，且高占用项有增长预算。
6. RAM/DSP 推断与设计意图一致。
7. Methodology、DRC 和 QoR warning 已逐类处理、解释或进入明确 backlog。
8. 板级使用前，补齐并验证真实 I/O delay、配置电压、bank 电压和外部器件
   时序。

`WNS > 0` 只满足第 3 项的一部分。

## 官方资料

- [UG901: Vivado Synthesis Overview](https://docs.amd.com/r/2025.2-English/ug901-vivado-synthesis/Overview)
- [UG901: Using Synthesis Settings](https://docs.amd.com/r/2025.2-English/ug901-vivado-synthesis/Using-Synthesis-Settings)
- [UG904: Implementation Strategy Descriptions](https://docs.amd.com/r/en-US/ug904-vivado-implementation/Implementation-Strategy-Descriptions)
- [UG904: phys_opt_design and route_design directives](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Directives-Used-by-phys_opt_design-and-route_design-in-Implementation-Strategies)
- [UG906: Reports](https://docs.amd.com/r/2025.2-English/ug906-vivado-design-analysis/Reports)
- [UG906: QoR Assessment Details](https://docs.amd.com/r/2025.2-English/ug906-vivado-design-analysis/QoR-Assessment-Details)
- [UG835: report_qor_assessment](https://docs.amd.com/r/en-US/Vivado-Design-Suite-Tcl-Command-Reference-Guide-UG835/report_qor_assessment)
