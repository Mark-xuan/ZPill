# Z30 STA 验证

默认版：24 张元数据一批、24 格缩略图一批；排序只针对已读取对象。文件头缓存最多 128 × 64 KiB，原图缓存 256 MiB，会话变化后不复用旧文件。主动下载优先于尚未开始的后台任务，不中断正在执行的事务或原图缓存任务。

## 构建

仓库根 PowerShell（已安装 Flutter、Java、Android SDK）：

```powershell
$env:JAVA_HOME = 'C:/Program Files/Java/jdk-21.0.6.7-hotspot'
$env:JAVA_TOOL_OPTIONS = '-Djavax.net.ssl.trustStoreType=Windows-ROOT -Djavax.net.ssl.trustStore=NONE'
./tools/build_z30_apk.ps1
```

脚本使用本工作区 build/android-sdk，临时排除 HarmonyOS OhosView 分支，改用 Gradle 官方源并保留 SHA256 校验，结束后恢复源码。输出 build/app/outputs/flutter-apk/zpill-z30.apk。

在「设置 → 传输与存储 → Z30 STA 下载档位」选择常规、512 KiB、1 MiB、2 MiB 或高速读取。选择后完整退出并重新打开应用，再连接相机。用下载日志中的 download profile mode 核对档位。实验档绕过原图缓存以免测到本地复制速度。大块被拒降为64 KiB；高速被拒或游标不符则终止、恢复应用模式，从头转0x9431。无法读取应用模式时不盲目改模式；链路超时/断开不盲目回退。高速全段独占会话，轮询与元数据不会插入。

## 实测

1. normal 进入图库，首批后元数据读取停止；继续上拉或点击追加一批。
2. 同会话刷新，确认旧条目不重读，新增/删除同步。
3. 预览后保存已完整读取的照片，查看原图缓存命中；后台缩略排队时主动下载，查看优先级和等待时间。
4. 在同一个 APK 中依次选固定 512 KiB、1 MiB、2 MiB 和高速读取，每次重启应用后测试同一照片，每档至少三次，保持网络、机位、相机状态一致并停止实时取景；每轮立刻导出日志，注明档位。
5. 测试取消、暂停恢复、断连重连、切换前后台，核对文件大小并打开照片。

## 日志

- download profile：句柄、大小、实验块、hs配置、续传偏移。
- download scheduled：priority=0主动、1后台，wait_ms原图队列等待。
- metadata stage：上限、已知对象数、总句柄数、more。
- head hit/read：命中或补读，offset为补读起点。
- exif thumbnail range / thumbnail source：定位读取偏移/长度及exif或original来源。
- 原图缓存命中：没有网络读取，传输页不计算虚假的网络速度。
- 协议响应：opcode/tid/rc/bytes/总ms，first_us发送到首个非空数据包，receive_us首包至末包，tail_us末包至响应，chunks包数。
- 上述计时是客户端完整数据包解析点，不是网卡抓包；单包receive_us=0不表示无限带宽。
- hs block/terminate/restore/fallback：游标校验、收尾、模式恢复和回退原因。
- download complete：实际读取字节和总耗时。hs=true是配置，不代表高速成功，要结合fallback判读。

普通日志即可，无需开启十六进制verbose。优化不保证3 MB/s，测试结果应保留拒答和回退记录。
