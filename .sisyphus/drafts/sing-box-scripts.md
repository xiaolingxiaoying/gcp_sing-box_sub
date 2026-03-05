# 草案：分析 sing-box-yg 和 vps-sub-meter 项目并创建脚本

## 原始请求
用户想要：
1. 学习 https://github.com/yonggekkk/sing-box-yg 中的 "Sing-box-yg精装桶一键五协议共存脚本（VPS专用）"
2. 学习 https://github.com/xiaolingxiaoying/vps-sub-meter 项目中的配置方式
3. 最终编写两个脚本：
   - 脚本1：基于 sing-box-yg 的脚本，但修复问题并添加通过 wrap 开启虚拟 IPv6 以使用 Cloudflare IPv6 地址的功能
   - 脚本2：可能是 vps-sub-meter 的改进版本或集成脚本

## 需求澄清
- 用户发现 yonggekkk 的脚本配置生成有问题
- 用户想要通过 wrap 开启虚拟 IPv6，以便使用 Cloudflare 的 IPv6 地址
- 用户想要结合两个项目的优点

## 需要研究的问题
1. sing-box-yg 项目的具体内容：脚本结构、协议配置、问题所在
2. vps-sub-meter 项目的具体内容：流量统计和订阅管理配置
3. wrap 虚拟 IPv6 的技术细节
4. Cloudflare IPv6 地址的使用方式

## 技术决策
待定

## 研究结果
待探索
### sing-box-yg 项目
- 主脚本：sb.sh（~144k 行）
- 功能：一键安装五协议共存（Vless-reality-vision, Vmess-ws(tls)/Argo, Hysteria-2, Tuic-v5, Anytls）
- 支持 IPv4/IPv6/双栈，支持 amd/arm 架构
- 包含 WARP 功能（用于分流和获取 IPv6 地址）
- 问题：用户反映配置生成有问题，具体未指明
- 可能的问题：WARP 配置、IPv6 设置、证书生成等

### vps-sub-meter 项目
- 主脚本：auto_setup.sh（约 1000 行）
- 功能：流量统计（vnstat）和订阅管理（Python HTTP 服务）
- 提供 Clash Meta (YAML) 和 sing-box (JSON) 订阅格式
- 使用 Caddy 反向代理提供 HTTPS + Basic Auth
- 依赖 sing-box-yg 生成的配置文件：/etc/s-box/clash_meta_client.yaml 和 /etc/s-box/sing_box_client.json

### WARP 虚拟 IPv6 技术
- Cloudflare WARP 是一个 VPN 服务，可以提供 IPv6 地址
- 用户可能希望在仅有 IPv4 的 VPS 上通过 WARP 获得 IPv6 地址，以便使用 Cloudflare 的 IPv6 CDN
- sb.sh 中已有 WARP 相关代码（warpcheck、wgcfgo 函数）

## 需要用户澄清的问题

**关于WARP IPv6问题：**
1. WARP IPv6 "用不了" 的具体表现是什么？
   - 是WARP客户端无法启动，还是IPv6地址未分配？
   - 是网络无法连接（ping不通），还是具体协议（如Vless、Hysteria）无法使用IPv6？
   - 是否有具体的错误日志或提示信息？

2. 您的VPS原生支持IPv6吗？还是只有IPv4，需要通过WARP获取IPv6？

3. 您希望WARP IPv6如何与sing-box配合使用？
   - 作为出站出口（所有流量经过WARP IPv6）
   - 作为备用出口（仅当IPv4不可用时）
   - 作为特定协议/IP的出口（分流）

**关于脚本改进：**
4. 对于vps-sub-meter的"更详细配置"，您希望具体在哪些方面增强？
   - 更多配置选项（如端口、路径、认证方式）
   - 更详细的验证和错误提示
   - 配置文件的导入/导出功能
   - 其他特定需求？

5. 两个脚本是否需要集成（脚本1生成配置，脚本2自动部署订阅服务），还是保持独立？

**技术细节：**
6. 您是否尝试过手动调试WARP IPv6问题？发现了什么线索？
7. 您使用的是sing-box-yg脚本的哪个版本/提交？

## 开放性问题
1. 用户具体遇到 yonggekkk 脚本的什么问题？
2. 用户希望脚本实现什么具体功能？
3. 两个脚本的具体分工是什么？
4. 目标操作系统和环境是什么？

## 范围边界
- INCLUDE：分析两个 GitHub 项目，创建修复和改进的脚本
- EXCLUDE：不确定
## 用户澄清后的需求
### 问题1：WARP IPv6 问题
- sing-box-yg 脚本生成了 IPv6 的 WARP 配置，但无法使用
- 需要修复 WARP IPv6 功能，使其正常工作

### 脚本分工
- 脚本1：修复并增强 sing-box-yg 脚本，明确添加 WARP IPv6 功能
- 脚本2：改进 vps-sub-meter 的配置过程，使其更详细

### 目标操作系统
- Ubuntu 22 及以上
- Debian 12, 13

### 技术方法
- 学习 sing-box-yg 脚本的实现方式
- 分析 WARP IPv6 无法使用的原因
- 修复 WARP 配置，确保 IPv6 地址可用
- 改进 vps-sub-meter 的交互式配置过程，提供更详细的提示和验证

## 技术决策
- 使用与 sing-box-yg 相同的依赖安装方式
- 保持与原有脚本的兼容性
- 确保 WARP IPv6 功能可配置（自动/手动）

## vps-sub-meter 详细分析结果
### 仓库结构
- README.md：极简使用说明（先运行上游脚本，再运行本项目脚本）
- auto_setup.sh：一键交互式安装/部署脚本（约1000行）

### 核心功能组件
1. 配置文件：/etc/sub-srv/config.conf（保存域名、账号、密码哈希、流量上限、时区、网卡、token等）
2. 订阅源文件副本：/var/lib/subsrv/client.yaml（Clash Meta）和 client.json（sing-box）
3. 每5分钟同步上游订阅文件（systemd timer）
4. 每月重置流量基线（systemd timer，每月1日00:00）
5. 动态订阅后端（Python HTTP Server，默认端口2080）
6. 对外入口（Caddy反向代理，HTTPS + BasicAuth + token免密）

### 流量统计实现
- 核心数据来源：sysfs的 tx_bytes（出口发送字节数）
- 通过本月基线 base_tx 求差得到本月已用
- subscription-userinfo响应头：upload=0; download=<used_tx>; total=<TOTAL_BYTES>; expire=<下次月初epoch>
- 注意：统计的是出口流量（tx_bytes），但显示在download字段

### 订阅管理实现
- 不生成节点/订阅内容，依赖上游脚本产物
- 对外路径：/sub/<token>.yaml 和 /sub/<token>.json
- 鉴权模型：BasicAuth 或 token 参数免密

### 关键发现
- 流量统计口径：出口发送（tx_bytes），upload固定为0
- 无限流量的呈现：LIMIT_GIB<=0时total设为1TiB（仅为显示）
- 订阅内容强依赖外部脚本（sing-box-yg）

### 脚本改进要点

#### vps-sub-meter 改进方向（脚本2）
- **更详细的交互式配置**：提供更多验证、默认值、示例说明
- **配置预览**：显示用户输入设置的摘要，确认后再应用
- **依赖检查增强**：验证上游文件是否存在并提供修复选项
- **安装进度可视化**：分步骤显示安装进度和组件状态
- **故障排查指南**：常见问题（端口占用、权限问题）的自动检测和解决方案
- **配置文件备份/恢复**：支持配置文件导出和导入
- **多种流量统计模式**：可选项（sysfs tx_bytes、vnstat 双向统计、Docker 容器统计）
- **灵活订阅路径**：支持自定义订阅URL路径前缀
- **多域名支持**：支持多个域名和负载均衡配置
- **更详细的状态报告**：部署完成后提供完整的服务状态、日志位置、监控命令

#### sing-box-yg 改进方向（脚本1）
- **WARP IPv6 问题修复**：分析具体失效原因（配置错误、网络路由、服务未启动）
- **WARP 配置增强**：提供 WARP 状态检查、手动切换模式（IPv4-only、IPv6-only、dual-stack）
- **协议配置优化**：协议选择的更详细说明和性能调优
- **错误处理增强**：更详细的安装失败诊断和回滚机制
- **配置验证**：生成配置后自动测试连接和协议可用性
- **模块化设计**：将 WARP 功能、协议配置、证书管理拆分为独立模块
- **日志记录**：详细的安装日志和调试信息输出
- **一键修复功能**：检测常见问题并提供自动修复选项

### 测试策略
- 单元测试：否（用户选择）
- Agent-Executed QA：所有任务将包含详细的Agent-Executed QA场景