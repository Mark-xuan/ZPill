# ptpip_probe — PTP-IP 协议验证 CLI(P0)

在写任何 Dart 协议代码之前,先用这个脚本对**真机**跑通握手、核对字节布局
(协议常量不可臆造,以真机响应为准)。

## 用法

```bash
# 前置:手动连接相机 WiFi 热点
python3 tools/ptpip_probe/probe.py 192.168.1.1
python3 tools/ptpip_probe/probe.py --hostname MacBook 192.168.1.1
```

零依赖,仅标准库(Python 3.10+)。

### 单张照片的图库对照

让电脑与相机处在同一网络，断开占用相机会话的 App，再传入本次连接中要验证的照片句柄。用同一张未标记上传的照片分别测试 AP 和 STA。

```powershell
python tools/ptpip_probe/probe.py <相机IP> --gallery-handle 689504361
```

此模式记录单个对象的元数据、缩略图和两种分块读取的响应码与长度。两种分块读取各请求 64 KiB，不保存照片。若句柄已变化，输出会列出当前会话最后几个句柄供核对。

加上 `--gallery-compare-remote` 可在同一个会话里执行一次 `ChangeCameraMode(1)` 再执行 `ChangeCameraMode(0)`，并比较切换前后的读取结果。该对照不会开启实时取景。

用 `--gallery-remote-first` 可在 `OpenSession` 成功后立即切换遥控模式，再读取同一个对象，核对 ZPill 的连接顺序。两个对照选项互斥。

要在同一台电脑上对照默认探针身份与已配对的 ZPill 身份，可从自己的 Android Debug 版本导出身份文件。以下命令在 Windows CMD 执行，手机需已通过 ADB 授权。品牌定制构建请替换包名。

```cmd
adb exec-out run-as com.jaminxx.zpill cat files/zpill-data/client_identity.json > "%TEMP%\zpill-client-identity.json"
python tools/ptpip_probe/probe.py 192.168.1.241 --gallery-handle 689504361 --client-identity "%TEMP%\zpill-client-identity.json"
```

用同一个相机 IP 和句柄，省略 `--client-identity` 再做一轮对照。开始前先断开手机 App 占用的相机会话。身份文件只留本机，分享探针输出即可。

### 配对完成后读取图库

相机已加入同一网络并处于等待配对时，用导出的 ZPill 身份请求配对。相机显示配对完成后，在机身按 J／OK，然后执行第二条命令。两条命令之间保持相机联网并让手机 App 断开。第二条命令在新的会话中直接读图库。

```cmd
python tools/ptpip_probe/probe.py 192.168.1.241 --gallery-pair --client-identity "%TEMP%\zpill-client-identity.json"
python tools/ptpip_probe/probe.py 192.168.1.241 --gallery-handle 689504361 --client-identity "%TEMP%\zpill-client-identity.json"
```

`--gallery-pair` 会在相机上配对该客户端。第二条命令还会记录逐属性读取 `0x9803`、文件大小 `0x9421` 和尼康分块读取 `0x9431` 的响应，用于验证配对后能否读取列表所需的字段和图片数据。

若 `0x9421` 和 `0x9431` 成功，可在第二条命令末尾加 `--gallery-download-jpeg "%TEMP%\z30-sta-test.jpg"`。探针会按相机返回的大小分块读取整张 JPEG，并核对文件头和结束标记。目标文件需为新文件，失败会清理本次下载的部分数据。

## 当前覆盖

- [x] command 通道 TCP 连接 + InitCommandRequest/Response
- [ ] event 通道(独立 socket)InitEventRequest/Response
- [ ] OpenSession(0x1002)
- [ ] GetObjectHandles(0x1007)解析
- [ ] 结论回填:Dart 侧 `DataPhaseInfo` 取值语义、NEF 的 ObjectFormatCode

## 排障速查

| 症状 | 首要怀疑 |
|---|---|
| TCP 连上但无任何响应 | 字节序错误(必须小端)或包长度字段错(含 8B 头) |
| 连接被立即关闭 | 主机名编码/长度字段错(UTF-16LE + u32 长度) |
| InitFail | 看 reason 码;对照 libgphoto2 ptpip.c |
| 15740 拒绝连接 | 确认 BLE 是否已激活相机 WiFi 服务(0x2005 写 0x01 激活,已定案) |
