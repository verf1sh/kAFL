#!/bin/bash
#
# setup.sh — 一键部署脚本 (kAFL firmware-fuzz 定制版)
#
# 小白用法：
#   git clone -b verf1sh/firmware-agent https://github.com/verf1sh/kAFL
#   cd kAFL
#   ./setup.sh
#
# 这个脚本会：
#   1. 拉取自定义 fuzzer (kafl.fuzzer 的 firmware-fuzz 分支)
#   2. 安装 Python 依赖
#   3. 编译 agent + hook
#   4. 打 QEMU 补丁
#   5. 生成工作目录配置 (config/)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ── 检查是否在 kAFL 仓库根目录 ────────────────────────────────────
if [ ! -f "Makefile" ] || [ ! -d "deploy" ]; then
    error "请在 kAFL 仓库根目录运行此脚本"
fi

info "当前路径: $SCRIPT_DIR"

# ── 1. 检查 kAFL 基础环境 ─────────────────────────────────────────
if [ ! -f "kafl/env.sh" ]; then
    warn "标准 kAFL 组件未安装 (kafl/env.sh 不存在)"
    warn "请先运行标准安装: make deploy"
    error "中止。请先执行标准 kAFL 部署。"
fi

source kafl/env.sh || error "无法加载 kafl/env.sh"

# ── 2. 拉取自定义 fuzzer ──────────────────────────────────────────
FUZZER_DIR="kafl/fuzzer"
FUZZER_REPO="https://github.com/verf1sh/kafl.fuzzer.git"
FUZZER_BRANCH="verf1sh/firmware-fuzz"

info "检查自定义 fuzzer ..."
if [ -d "$FUZZER_DIR/.git" ]; then
    info "fuzzer 已存在，切换到 $FUZZER_BRANCH 分支"
    cd "$FUZZER_DIR"
    git remote add custom "$FUZZER_REPO" 2>/dev/null || true
    git fetch custom "$FUZZER_BRANCH" || error "拉取 fuzzer 分支失败"
    git checkout -B "$FUZZER_BRANCH" "custom/$FUZZER_BRANCH" || error "切换分支失败"
    cd "$SCRIPT_DIR"
else
    info "克隆自定义 fuzzer ..."
    git clone -b "$FUZZER_BRANCH" "$FUZZER_REPO" "$FUZZER_DIR" || error "克隆失败"
fi

# ── 3. 安装 Python 依赖 ───────────────────────────────────────────
info "安装 fuzzer Python 依赖 ..."
cd "$FUZZER_DIR"
if [ -f "pyproject.toml" ]; then
    pip install -e . || warn "pip install -e . 失败，尝试 requirements.txt"
elif [ -f "setup.py" ]; then
    pip install -e . || warn "pip install -e . 失败"
fi
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt || warn "requirements.txt 安装失败"
fi
cd "$SCRIPT_DIR"

# ── 4. 编译 agent + hook ──────────────────────────────────────────
AGENT_DIR="$SCRIPT_DIR/kafl/examples/firmware/ivanti"

info "编译 agent + hook ..."
if [ -d "$AGENT_DIR" ]; then
    cd "$AGENT_DIR"
    make clean 2>/dev/null || true
    make || error "编译 agent 失败"
    cd "$SCRIPT_DIR"
else
    warn "agent 目录不存在: $AGENT_DIR"
    warn "请先运行: make deploy -- --tags examples"
fi

# ── 5. 打 QEMU 补丁 ──────────────────────────────────────────────
QEMU_PATCH="$SCRIPT_DIR/patches/0001-nyx_debug-instead-of-nyx_warn.patch"
QEMU_DIR="$SCRIPT_DIR/kafl/qemu"

if [ -f "$QEMU_PATCH" ] && [ -d "$QEMU_DIR" ]; then
    info "应用 QEMU 补丁 ..."
    cd "$QEMU_DIR"
    # 检查是否已经打过
    if grep -q 'nyx_debug("Root snapshot is not available yet' "nyx/synchronization.c" 2>/dev/null; then
        info "QEMU 补丁已应用，跳过"
    else
        git apply "$QEMU_PATCH" || warn "打补丁失败，请手动检查"
    fi
    cd "$SCRIPT_DIR"
else
    warn "QEMU 补丁文件或目录不存在，跳过"
fi

# ── 6. 生成工作目录配置 ───────────────────────────────────────────
CONFIG_DIR="$SCRIPT_DIR/config"
mkdir -p "$CONFIG_DIR"

# 从 example 目录复制配置文件
IVANTI_DIR="$SCRIPT_DIR/kafl/examples/firmware/ivanti"

if [ ! -f "$CONFIG_DIR/kafl.yaml" ] && [ -f "$IVANTI_DIR/kafl.yaml" ]; then
    info "生成 kafl.yaml ..."
    cp "$IVANTI_DIR/kafl.yaml" "$CONFIG_DIR/kafl.yaml"
    # 替换 qcow2 路径为提示
    sed -i "s|/path/to/Ivanti.qcow2|/path/to/your/Ivanti.qcow2|g" "$CONFIG_DIR/kafl.yaml"
else
    warn "$CONFIG_DIR/kafl.yaml 已存在或 example 配置不存在，跳过"
fi

if [ ! -f "$CONFIG_DIR/strategy.yaml" ] && [ -f "$IVANTI_DIR/strategy.yaml" ]; then
    info "生成 strategy.yaml ..."
    cp "$IVANTI_DIR/strategy.yaml" "$CONFIG_DIR/strategy.yaml"
else
    warn "$CONFIG_DIR/strategy.yaml 已存在或 example 配置不存在，跳过"
fi

# ── 7. 生成 agent 策略文件 (strategy.txt) ───────────────────────────
if [ -f "$IVANTI_DIR/strategy.yaml" ] && [ -f "$FUZZER_DIR/scripts/generate_agent_config.py" ]; then
    info "生成 agent strategy.txt ..."
    python3 "$FUZZER_DIR/scripts/generate_agent_config.py" \
        --strategy "$IVANTI_DIR/strategy.yaml" \
        --output "$CONFIG_DIR/strategy.txt" \
        --seed-dir "$IVANTI_DIR" \
        || warn "生成 strategy.txt 失败，请手动运行 generate_agent_config.py"
else
    warn "缺少 strategy.yaml 或 generate_agent_config.py，跳过 strategy.txt 生成"
fi

# ── 完成 ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "下一步："
echo "  1. 准备 Ivanti.qcow2 镜像"
echo "  2. 编辑 config/kafl.yaml，填写 qcow2 路径和 PT trace 范围 (ip0)"
echo "  3. 将 config/strategy.txt 拷贝到 VM 内部"
echo "  4. 在 VM 内运行: ./agent strategy.txt"
echo "  5. 在宿主机运行: kafl fuzz --config config/kafl.yaml -w /tmp/ivanti_fuzz"
echo ""
echo "靶子目录: kafl/examples/firmware/ivanti/"
echo "  - make          编译 agent"
echo "  - replay_crash.py  重放 crash"
echo ""
echo "详细说明见: templates/setup_guide.md"
