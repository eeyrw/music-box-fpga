# Smart Artix Vivado Assets

`ip/` 保存 clock 与 DDR3 MIG 配置，`scripts/` 保存工程、综合、实现、bitstream 和报告
流程。这些资产没有随旧 renderer 删除，因为器件、MIG 和报告流程仍会被新 board
top 复用。

当前 `smart_artix_top` 尚未重建，所以脚本不是可立即生成 bitstream 的完成工程。
接入新 top 后需要同步更新 `fpga/smart_artix/filelist.f`、时钟/IO 约束和脚本的 top
设置，再运行综合与实现验证。
