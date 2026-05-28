# kAFL firmware-fuzz 项目架构

## 1. 仓库关系

整个项目由 **3 个仓库** 组成，职责分离：

```
┌─────────────────────────────────────────────────────────────┐
│  kAFL (verf1sh/kAFL)                                        │
│  ├── deploy/          Ansible 部署脚本 (make deploy)         │
│  ├── setup.sh         一键配置自定义 fuzzer + agent 编译      │
│  ├── patches/         QEMU 补丁                             │
│  ├── templates/       配置模板 (strategy.yaml 说明文档)      │
│  └── seeds/           额外种子 (可选)                        │
│                                                             │
│  依赖 ──clone──► kafl.fuzzer (verf1sh/kafl.fuzzer)         │
│  依赖 ──clone──► kafl.targets (verf1sh/kafl.targets)       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  kafl.fuzzer (verf1sh/kafl.fuzzer)                          │
│  ├── kafl_fuzzer/technique/template_engine.py   协议解析引擎 │
│  ├── kafl_fuzzer/technique/strategy_mutator.py  策略变异器   │
│  ├── kafl_fuzzer/manager/manager.py             种子校验    │
│  ├── kafl_fuzzer/manager/scheduler.py           调度惩罚    │
│  └── scripts/generate_agent_config.py           生成策略文件 │
│                                                             │
│  职责：读取 strategy.yaml，字段级变异，Bandit 调度           │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  kafl.targets (verf1sh/kafl.targets)                        │
│  └── firmware/ivanti/                                       │
│      ├── kafl.yaml         靶子配置                          │
│      ├── strategy.yaml     协议模板 + 包序列                 │
│      ├── seeds/            prefix 种子                       │
│      ├── agent.c           VM 内 agent (TLS + 超调用)        │
│      ├── hook_SSL_read.c   LD_PRELOAD hook                   │
│      └── Makefile          编译 agent + hook                 │
│                                                             │
│  职责：和 dvkm 一样，自包含的 fuzz 靶子                      │
└─────────────────────────────────────────────────────────────┘
```

## 2. 数据流

```
宿主机 (Host)
  ├─ kafl fuzz --config kafl.yaml
  │   ├─ strategy_mutator 读取 strategy.yaml (协议模板)
  │   ├─ 字段级变异 → 生成 fuzz payload
  │   └─ 通过 hypercall 写入 VM 共享内存
  │
  └─ QEMU (打补丁 nyx_warn→nyx_debug)
      └─ VM (Ivanti qcow2)
          ├─ agent (编译自 agent.c)
          │   ├─ TLS connect 127.0.0.1:443
          │   ├─ 发送 prefix 包 (HTTP upgrade + IFT version)
          │   ├─ NEXT_PAYLOAD → 从 SHM 读取 fuzz 数据
          │   └─ SSL_write → 发送 fuzz payload
          │
          └─ web daemon (/home/bin/web)
              ├─ SSL_read (被 hook 拦截，注入 SHM 数据)
              └─ 处理 IFT key=value → strncpy 溢出 (CVE-2025-0282)
```

## 3. 部署步骤 (另一个用户)

### 前置条件

| 项目 | 要求 |
|------|------|
| 宿主机 OS | Ubuntu 22.04+ (kAFL 官方支持) |
| 内存 | ≥ 32 GB (QEMU + PT trace 开销大) |
| 磁盘 | ≥ 100 GB (qcow2 镜像 + 工作目录) |
| CPU | Intel (Intel PT 必需) |
| 网络 | 已配置 tap0 网桥 (VM 与宿主机通信) |
| VM 镜像 | Ivanti Connect Secure qcow2 |

### 步骤 1: 克隆并部署 kAFL

```bash
git clone -b verf1sh/firmware-agent https://github.com/verf1sh/kAFL
cd kAFL

# 标准 kAFL 部署 (QEMU + libxdc + capstone + fuzzer + examples)
make deploy -- --tags examples

# 加载环境
source kafl/env.sh
```

**这会做什么：**
- 从 `verf1sh/kafl.targets` 拉取 examples (含 `firmware/ivanti/`)
- 从 `IntelLabs/kafl.fuzzer` 拉取默认 fuzzer
- 编译 QEMU、libxdc、capstone

### 步骤 2: 运行 setup.sh (替换为自定义 fuzzer)

```bash
./setup.sh
```

**这会做什么：**
1. 将 `kafl/fuzzer/` 替换为 `verf1sh/kafl.fuzzer` (firmware-fuzz 分支)
2. `pip install -e .` 安装自定义 fuzzer
3. 编译 `kafl/examples/firmware/ivanti/` 下的 agent + hook
4. 打 QEMU 补丁 (`nyx_warn` → `nyx_debug`)
5. 生成 `config/` 目录 (含策略文件)

### 步骤 3: 配置 kafl.yaml

编辑 `kafl/examples/firmware/ivanti/kafl.yaml`：

```yaml
# 必须修改:
qemu_image: /path/to/your/Ivanti.qcow2
ip0: 0x56000000-0x58000000   # 通过 VM 内 cat /proc/$(pidof web)/maps 获取
```

### 步骤 4: 启动 fuzz

```bash
cd kafl/examples/firmware/ivanti
make                          # 确保 agent 已编译

# 在 VM 内启动 agent (通过 SSH 或串口)
# ./agent strategy.txt

# 在宿主机启动 fuzz
kafl fuzz --config kafl.yaml -w /tmp/ivanti_fuzz
```

## 4. 关键文件说明

| 文件 | 位置 | 作用 |
|------|------|------|
| `kafl.yaml` | `kafl/examples/firmware/ivanti/` | fuzz 主配置 (qcow2、ip0、变异器) |
| `strategy.yaml` | `kafl/examples/firmware/ivanti/` | 协议模板 (IFT/HTTP 字段定义) |
| `strategy.txt` | 由 `generate_agent_config.py` 生成 | agent 读取的简化配置 (prefix 数量) |
| `agent` | 编译输出 | VM 内运行的 fuzz agent |
| `hook_SSL_read.so` | 编译输出 | LD_PRELOAD hook，拦截 SSL_read |

## 5. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `Coverage bitmap is empty` | PT trace 范围 (ip0) 错误 | 在 VM 内执行 `cat /proc/$(pidof web)/maps`，核对地址 |
| `No inputs in queue` | prefix 期间 RELEASE 过早 | hook 的 `prefix_phase` 逻辑已处理 |
| agent 编译失败 | 缺少 `libnyx_agent.a` | 先运行 `make deploy` |
| `kafl fuzz: command not found` | 未加载环境 | `source kafl/env.sh` |

## 6. 分支对应关系

| 仓库 | 分支 | 说明 |
|------|------|------|
| kAFL | `verf1sh/firmware-agent` | 部署脚本 + QEMU 补丁 |
| kafl.fuzzer | `verf1sh/firmware-fuzz` | 自定义变异器 + 模板引擎 |
| kafl.targets | `verf1sh/firmware-fuzz` | Ivanti 靶子 |
