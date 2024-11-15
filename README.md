> ### 脚本简介
> 
> 简单懒人服务器初始化工具，主要用于以下任务：
> 
> 1.  **更新系统**：更新 Ubuntu 系统的软件包和安装最新的安全补丁。
> 2.  **安装必备软件**：
>     *   **curl**：用于下载文件。
>     *   **UFW 防火墙**：配置并启用防火墙，允许 SSH 端口连接。
>     *   **Fail2ban**：防止暴力破解 SSH 登录，通过限制错误登录次数提高服务器安全性。
>     *   **Docker**：安装并配置 Docker 容器引擎，并可以选择是否更新 UFW 配置以支持 Docker。
>     *   **Docker Compose**：安装 Docker Compose 工具，简化容器管理。
>     *   **ZeroTier**：安装并配置 ZeroTier，提供虚拟局域网支持，可以通过 ZeroTier 网络访问服务器。
> 3.  **SSH 安全设置**：
>     *   **修改 SSH 端口**：允许用户指定 SSH 服务的端口号（默认为 22），以提高安全性。
>     *   **开启 SSH 密钥认证**：禁用密码登录，仅允许 SSH 密钥认证，以加强 SSH 登录的安全性。
> 
> ### 主要功能概览
> 
> 1.  **系统更新**：通过 `apt update` 和 `apt upgrade` 更新系统软件。
> 2.  **安装必要的工具**：
>     *   安装 `curl` 用于后续下载。
>     *   安装并配置 `UFW` 防火墙。
>     *   安装并配置 `Fail2ban` 防止暴力攻击。
> 3.  **容器支持**：
>     *   安装 Docker 引擎。
>     *   配置 Docker 和 UFW 防火墙的兼容性。
>     *   安装 Docker Compose 用于容器编排。
> 4.  **ZeroTier 安装与配置**：安装 ZeroTier 并加入指定网络，设置允许 ZeroTier 网络的 IP 段访问 SSH。
> 5.  **SSH 配置**：
>     *   修改 SSH 端口。
>     *   配置仅允许 SSH 密钥认证登录，提高安全性。
> 
> ### 使用场景
> 
> *   **服务器初始化**：适用于新安装的 Ubuntu 系统，帮助用户快速配置防火墙、SSH、安全设置和 Docker 环境。
> *   **安全加固**：自动化配置 SSH 密钥认证、修改默认 SSH 端口、启用 Fail2ban，提升系统安全性。
> *   **容器部署**：快速安装 Docker 和 Docker Compose，简化容器化应用的部署。
> *   **虚拟网络配置**：通过 ZeroTier 创建虚拟局域网，实现与其他设备的安全通信。
> 
> ### 执行流程
> 
> 1.  **更新系统**：脚本会通过 `apt update` 和 `apt upgrade` 更新系统的软件包。
> 2.  **安装和配置必要工具**：
>     *   安装 `curl`、`UFW`、`Fail2ban` 等。
>     *   配置并启动 `UFW` 防火墙，设置规则以允许 SSH 连接。
>     *   安装 Docker 和 Docker Compose，配置防火墙以支持 Docker。
> 3.  **修改 SSH 配置**：
>     *   用户可以自定义 SSH 端口，脚本会更新 `/etc/ssh/sshd_config` 文件。
>     *   配置 SSH 只允许密钥认证登录，禁用密码认证。
> 4.  **安装和配置 ZeroTier**：
>     *   脚本自动安装 ZeroTier，并通过提供的网络密钥加入指定的 ZeroTier 网络。
>     *   获取 ZeroTier 分配的 IP 地址，并配置防火墙允许该 IP 段访问 SSH。
> 5.  **容器与网络设置**：
>     *   安装 Docker 和 Docker Compose。
>     *   设置 ZeroTier 网络规则，确保 ZeroTier 网络的 IP 段可以访问服务器。
> 6.  **是否重启服务器**：在所有配置完成后，脚本会询问用户是否重启服务器。
> 
> ### 使用方式
> 
> *   **运行脚本**：执行该脚本时，用户可以选择是否安装 Docker、Docker Compose、ZeroTier 等，输入自定义的 SSH 端口，配置 SSH 密钥认证，并决定是否重启服务器。
>*   给脚本赋予执行权限：
>*   `chmod +x init_server.sh`
>*   运行脚本：
>*   `sudo ./init_server.sh`
