# TF-HDMI 诊断工程

这是 `lab_ex4_tf` 六月纯视频源码的干净工作副本，用于阶段 0 的原样重编译和黑屏诊断。

## 来源

原始目录：

`D:\HX4S20_Contest_202606\7_lab_ex_2026_nosoft\aaa\lab_ex4_tf\src`

工作工程：

`D:\fpga\project\fpga\tf_hdmi_diag\td_project\lab_ex5_i2s_v1.0.al`

除本说明文件外，初始副本中的工程、HDL、IP 和约束文件均与官方源文件哈希一致。副本没有携带官方 `_Runs`、日志和历史 bitstream。

## 第一次打开

1. 启动 Tang Dynasty 6.2.1。
2. 使用 `File -> Open Project` 打开工作工程 `.al`，不要打开官方资源包中的同名文件。
3. 如果 TD 询问是否更新工程路径或保存工程，允许它更新工作副本。
4. 暂时不要开始综合。
5. 核对工程名为 `lab_ex5_i2s_v1.0`，目标器件为 `EG4S20BG256`，顶层模块为 `top`。
6. 检查 Sources/Design Sources 中是否有红色叉号、问号或 Missing File 提示。

确认工程完整打开后，再依次执行综合、布局布线和 bitstream 生成。第一轮不修改任何 HDL、IP 参数或约束。

## 上板限制

原样重编译生成的 bitstream 只先做 SRAM/JTAG 临时下载，不写配置 Flash。保持 TF 卡、4 张官方 BMP、HDMI 线和显示器不变，以便和四月/六月官方 bit 做有效对比。
