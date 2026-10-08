#!/usr/bin/env bash
# 修正 CANN 9.2.0-beta.1 的 ascendc_impl_build.py 生成的 impl .py：
# 该脚本会给 string 类型属性的默认值多套一层引号，生成出
#   def some_op(..., input_layout=""BNSD"", ...)
# 这种非法 Python，opc 解析这些 .py 时会直接 SyntaxError。
# 这里把重复的引号还原成正常的字符串字面量。
set -euo pipefail

target_dir="${1:-}"
if [ -z "${target_dir}" ] || [ ! -d "${target_dir}" ]; then
    echo "WARN: ${target_dir} not found, skip fixing impl py quotes" >&2
    exit 0
fi

find "${target_dir}" -name '*.py' -print0 | xargs -0 -r sed -i -E 's/=""([^"]*)""/="\1"/g'