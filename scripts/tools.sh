#!/usr/bin/env bash
# Проверка, что нужные инструменты установлены.
set -u

req=(docker uv python3 hadolint)
opt=(trivy dive jq)

status=0

echo
echo "Обязательные:"
for tool in "${req[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-12s %s\n' "$tool" "$("$tool" --version 2>&1 | head -n1)"
  else
    printf '  \033[31m✗\033[0m %-12s не найден\n' "$tool"
    status=1
  fi
done

echo
echo "Желательные (нужны для полной картины, но табло без них работает):"
for tool in "${opt[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-12s %s\n' "$tool" "$("$tool" --version 2>&1 | head -n1)"
  else
    printf '  \033[2m–\033[0m %-12s не найден\n' "$tool"
  fi
done
echo

exit $status
