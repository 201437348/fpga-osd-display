# 亮度/对比度移植记录

已从 `project-master (1)` 移植 `param_menu_controller.v`、`brightness_contrast_adjust.v`、顶层 KEY3/SW1..SW4 接口、参数跨时钟域提交和 pin 约束。图像处理位于视频复用器与 OSD 之间，因此只调整图片本身，OSD 保持全亮。音频播放链路保持原样。
