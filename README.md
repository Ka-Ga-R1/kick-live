# Kick Live Manager

<div align="center">

Kick 直播 HLS 中转管理脚本

把 Kick 直播间整理成固定播放地址和 M3U 播放列表。

</div>

## 简介

Kick Live Manager 用于在 VPS 上拉取 Kick 直播流，并通过 Nginx 对外提供固定的 HLS 地址。

脚本默认使用 `ffmpeg -c copy`，只做重新封装，不做转码。适合低配 VPS 给播放器、电视盒子、IPTV 客户端使用。

## 主要功能

1. 菜单式管理直播间。
2. 支持任意 Kick 直播间。
3. 根据 `yt-dlp` 解析结果选择实际可用清晰度。
4. 清晰度中文显示，例如 `1080P 60帧`、`720P`、`480P`。
5. 目标清晰度不可用时自动回退。
6. 每个直播间使用独立 systemd 服务。
7. 自动生成 M3U 播放列表。
8. 支持 Nginx 和 Certbot HTTPS。

## 快速开始

使用 root 用户执行：

```bash
curl -fsSL -o /usr/local/bin/kick-live https://raw.githubusercontent.com/你的用户名/你的仓库/main/kick-live-manager/kick-live.sh && chmod +x /usr/local/bin/kick-live && kick-live
```

之后再次打开管理菜单：

```bash
kick-live
```

## 系统要求

- Debian / Ubuntu
- root 权限
- 一个已经解析到 VPS 的域名
- VPS 开放 `80` 端口
- 如需 HTTPS，开放 `443` 端口

## 使用流程

1. 运行 `kick-live`
2. 选择 `安装/更新环境`
3. 选择 `配置域名和 HTTPS`
4. 选择 `添加直播间`
5. 输入 Kick 频道名
6. 输入本地名称，例如 `xpl1`
7. 选择解析出来的清晰度
8. 选择 `生成播放列表`

播放列表地址：

```text
https://你的域名/playlist.m3u
```

单路播放地址：

```text
https://你的域名/live/本地名称/index.m3u8
```

## 菜单预览

```text
 Kick 直播中转一键管理脚本 [v1.0.0]

  0. 升级脚本
 ———————————————————————
  1. 安装/更新环境
  2. 卸载环境
 ———————————————————————
  3. 配置域名和 HTTPS
  4. 查看播放列表
 ———————————————————————
  5. 添加直播间
  6. 管理直播间
  7. 生成播放列表
 ———————————————————————
  8. 查看全局状态
  9. 查看实时日志
 10. 清空日志
 ———————————————————————

 环境状态: 已安装 | Nginx 已启动
 当前域名: kick.example.com
 直播间数量: 2
 播放列表: https://kick.example.com/playlist.m3u

 请输入数字 [0-10]:
```

## 清晰度选择

添加或修改直播间时，脚本会读取 Kick 当前可用格式，并只显示解析出来的清晰度。

示例：

```text
  1. 1080P 60帧
  2. 720P 60帧
  3. 480P
```

保存配置时不会固定某一次的临时播放地址。拉流进程每次启动都会重新解析格式，优先选择目标清晰度，失败时向下回退。

## 安装位置

```text
/usr/local/bin/kick-live
/usr/local/bin/kick-live-worker
/etc/kick-live/config.env
/etc/kick-live/streams/*.env
/etc/systemd/system/kick-live@.service
/etc/nginx/sites-available/kick-live
/var/www/html/live/<name>/index.m3u8
/var/www/html/playlist.m3u
```

## 常用命令

查看某一路日志：

```bash
journalctl -u kick-live@名称 -f
```

查看 Nginx 状态：

```bash
systemctl status nginx
```

检查输出流：

```bash
ffprobe -hide_banner https://你的域名/live/名称/index.m3u8
```

## 卸载

运行：

```bash
kick-live
```

选择 `卸载环境`。

卸载会删除脚本生成的配置、systemd 服务、HLS 目录和播放列表，不会卸载 `nginx`、`ffmpeg`、`yt-dlp` 等系统软件包。
