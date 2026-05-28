# kAFL firmware-fuzz 快速部署指南

> 面向小白的完整部署流程，目标：一行命令配置完成。

---

## 1. 一键部署 (宿主机)

```bash
git clone -b verf1sh/firmware-agent https://github.com/verf1sh/kAFL
cd kAFL
./setup.sh
```

脚本会自动完成：
- 拉取自定义 fuzzer (`verf1sh/firmware-fuzz` 分支)
- 安装 Python 依赖
- 编译 agent + hook
- 打 QEMU 补丁 (nyx_warn → nyx_debug)
- 生成 `config/kafl.yaml` 和 `config/strategy.yaml`
- 复制种子到 `config/seeds/`

---

## 2. 手动修改配置

### 2.1 编辑 `config/kafl.yaml`

**必须修改的项目：**

| 字段 | 说明 | 示例 |
|------|------|------|
| `qemu_image` | VM 镜像路径 | `/path/to/Ivanti.qcow2` |
| `ip0` | PT trace 过滤范围 | `0x56000000-0x58000000` |

**获取 ip0 的方法：**
```bash
# 在 VM 内启动 web 守护进程后
$ cat /proc/$(pidof web)/maps | head
# 找到 [heap] 或 [stack] 附近的可执行段范围
```

### 2.2 编辑 `config/strategy.yaml`

- 如果目标协议是 **IFT-TLS 多包**：保持默认 (prefix ×2 + ift_binary)
- 如果目标协议是 **HTTP 单包**：注释掉 prefix + ift_binary，取消 `http_request` 注释

---

## 3. 准备 VM 内部环境

把以下文件拷贝到 VM 内任意目录：

```
agent              # 编译好的 64-bit agent
hook_SSL_read.so   # 32-bit LD_PRELOAD hook
config/strategy.txt   # setup.sh 自动生成
config/strategy.yaml  # (可选) agent 通过 strategy.txt 读取
```

### 3.1 生成 strategy.txt (如 setup.sh 未生成)

```bash
python3 kafl/fuzzer/scripts/generate_agent_config.py \
    --strategy config/strategy.yaml \
    --output config/strategy.txt \
    --seed-dir config/seeds
```

### 3.2 启动 agent (VM 内)

```bash
# 方式一：使用默认策略文件 (./strategy.txt)
./agent

# 方式二：指定策略文件
./agent /path/to/strategy.txt

# 方式三：带 hook 启动 (如果需要拦截 SSL_read)
LD_PRELOAD=./hook_SSL_read.so ./agent
```

---

## 4. 启动 fuzz (宿主机)

```bash
# 先加载 kAFL 环境
source kafl/env.sh

# 启动 fuzz
kafl fuzz --config config/kafl.yaml -w /tmp/ivanti_fuzz
```

---

## 5. 部署验证清单

| 检查项 | 命令 |
|--------|------|
| 环境已加载 | `echo $QEMU_ROOT` |
| fuzzer 已安装 | `kafl --version` |
| agent 已编译 | `file kafl/examples/firmware/ivanti/agent` |
| hook 已编译 | `file kafl/examples/firmware/ivanti/hook_SSL_read.so` |
| QEMU 补丁已打 | `grep nyx_debug kafl/qemu/nyx/synchronization.c` |
| 种子存在 | `ls config/seeds/` |
| VM 内 agent 可运行 | `ssh vm ./agent --help` |

---

## 6. 故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| `kafl fuzz: command not found` | 未加载 env.sh | `source kafl/env.sh` |
| `Coverage bitmap is empty` | PT trace 范围错误 | 核对 `ip0` 地址 |
| `No inputs in queue` | prefix 期间 RELEASE 过早 | 检查 hook 的 prefix_phase 逻辑 |
| agent 编译失败 | 缺少 libnyx_agent.a | 先运行 `make deploy` |
| `strategy.txt not found` | 未生成或路径错误 | 运行 generate_agent_config.py |
