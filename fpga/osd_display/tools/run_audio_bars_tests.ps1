param([string]$OutputDirectory = '')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(!$OutputDirectory){$OutputDirectory=Join-Path $projectRoot 'audio_bars_Runs/tests'}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
# osd_font_rom 的仿真模型按相对工程目录的路径读字库
Set-Location $projectRoot
$tests=@{
 'tb_audio_spectrum_fft'=@('rtl/audio/audio_spectrum_fft.v');
 'tb_audio_spectrum_bands'=@('rtl/audio/audio_spectrum_bands.v');
 'tb_audio_band_processor'=@('rtl/audio/audio_band_processor.v');
 'tb_audio_bars_overlay'=@('rtl/video/audio_bars_overlay.v');
 'tb_audio_spectrum_pipeline'=@('rtl/audio/audio_spectrum_fft.v','rtl/audio/audio_spectrum_bands.v','rtl/audio/audio_band_processor.v');
 'tb_video_osd_overlay'=@('rtl/video/video_osd_overlay.v','rtl/video/audio_bars_overlay.v');
 'tb_video_osd_regression'=@('rtl/video/video_osd_overlay.v','rtl/video/audio_bars_overlay.v','tests/fixtures/video_osd_overlay_reference.v');
 'tb_audio_pcm_player'=@('rtl/audio/audio_pcm_player.v');
 'tb_hdmi_audio_acr'=@('rtl/audio/hdmi_audio_acr.v');
 'tb_brightness_contrast_adjust'=@('rtl/video/brightness_contrast_adjust.v');
 'tb_param_menu_controller'=@('rtl/control/param_menu_controller.v');
 'tb_screen_uart_link'=@('rtl/control/param_menu_controller.v');
 'tb_osd_settings_panel'=@('rtl/video/osd_settings_panel.v','rtl/video/osd_font_rom.v')
}
$results=@()
foreach($name in ($tests.Keys | Sort-Object)){
 $sources=@((Join-Path $projectRoot "tests/$name.sv"))
 $sources += $tests[$name] | ForEach-Object {Join-Path $projectRoot $_}
 $out=Join-Path $OutputDirectory "$name.vvp"
 & iverilog -g2012 -s $name -o $out $sources
 if($LASTEXITCODE){throw "$name compile failed"}
 $log=& vvp $out
 $log | Tee-Object -FilePath (Join-Path $OutputDirectory "$name.txt")
 if($LASTEXITCODE){throw "$name simulation failed"}
 $results += $log
}
$rtl=Get-ChildItem (Join-Path $projectRoot 'rtl/audio'),(Join-Path $projectRoot 'rtl/video'),(Join-Path $projectRoot 'rtl/control'),(Join-Path $projectRoot 'rtl/storage'),(Join-Path $projectRoot 'rtl/image') -Filter *.v | ForEach-Object FullName
$src=@('rtl/top/top.v','tests/top_compile_stubs.v','ip/anlogic/afifo_16_32_256.v','ip/anlogic/afifo_32_16_256.v') | ForEach-Object {Join-Path $projectRoot $_}
& iverilog -g2012 -s top -o (Join-Path $OutputDirectory 'top.vvp') $src $rtl
if($LASTEXITCODE){throw 'Top elaboration failed'}
$results+='PASS top elaboration (vendor black boxes; not hardware simulation)'
$results | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'results.txt')
