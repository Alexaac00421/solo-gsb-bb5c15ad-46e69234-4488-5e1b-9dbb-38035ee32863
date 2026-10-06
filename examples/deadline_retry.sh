#!/usr/bin/env bash
# 本轮修复端到端示例: 评审截止设置的"响应丢失后同参数重试"幂等性
#
# 背景: 会务方为当前发布版设置截止成功后, 若该次 HTTP 响应丢失, 调用方会在
# 截止到点后用相同参数重试。旧接口把"时刻必须晚于当前时刻"的校验放在写事务
# 之前, 重试会被误判为"过期时刻"返回 422, 调用方无法确认首次设置是否生效。
#
# 修复后的判定顺序 (均在同一个 BEGIN IMMEDIATE 写事务内):
#   1. 尚未发布 -> 404
#   2. 核对当前发布版与 base_revision / base_serial -> 不符 409
#   3. 按归一化后的 UTC 时刻判断同版已存设置:
#        同值 -> 返回原设置 changed=false (即使截止已过; 不写新行、不推进版本号)
#        异值 -> 409 (不覆盖)
#   4. 首次设置才要求时刻严格晚于服务端当前时刻; 非法/无时区 -> 422
#
# 用法: ./examples/deadline_retry.sh [BASE_URL]   (建议对新库运行)
set -euo pipefail

BASE="${1:-http://localhost:8000}"
ORG="X-Organizer-Key: ${ORGANIZER_KEY:-dev-organizer-key}"
j() { python3 -c 'import sys, json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

echo "== 1. 录入两名不同机构评审人与论文 P1 =="
curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "reviewer_id": "R1", "credential": "r1-secret", "topics": ["AI"],
  "institution": "Inst-A", "capacity": 3, "avoid_papers": []}'
curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "reviewer_id": "R2", "credential": "r2-secret", "topics": ["AI"],
  "institution": "Inst-B", "capacity": 3, "avoid_papers": []}'
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P1", "manuscript": "P1 匿名稿全文...", "topics": ["AI"], "institutions": ["Univ-X"]}'

echo "== 2. 普通预演并发布, 记下 revision / serial =="
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
SER=$(curl -s -X POST "$BASE/assignment/publish" -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV}" | j 'd["serial"]')
echo "    revision=$REV serial=$SER"

# 截止时刻取服务端当前 UTC 时刻 +4 秒 (真实使用可直接给 2026-11-01T12:00:00Z / +08:00)
DEADLINE=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(seconds=4)).isoformat().replace("+00:00","Z"))')

echo "== 3. 首次设置截止 (服务端已成功落库; 假设本次响应在网络中丢失) =="
curl -s -X POST "$BASE/review-deadline" -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"$DEADLINE\"}" \
  | j "{'changed': d['changed'], 'serial': d['serial'], 'deadline_at': d['review_deadline']['deadline_at']}"

echo "== 4. 等待截止到点 (6 秒) =="
sleep 6
curl -s "$BASE/review-deadline" -H "$ORG" | j "{'deadline_expired': d['deadline_expired']}"

echo "== 5. 响应丢失后的相同参数重试: 取回原设置, changed=false (不再误判 422) =="
code=$(curl -s -o /tmp/dl_retry_resp.json -w '%{http_code}' -X POST "$BASE/review-deadline" -H "$ORG" \
  -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"$DEADLINE\"}")
cat /tmp/dl_retry_resp.json \
  | j "{'changed': d['changed'], 'deadline_at': d['review_deadline']['deadline_at'], 'set_at': d['review_deadline']['set_at']}"
echo "    HTTP $code"

echo "== 6. 同一时刻的不同时区表示 (UTC 时刻换算为 +08:00) 重试, 归一化后同值, 仍 changed=false =="
# 把第 3 步的 UTC 时刻换算为 +08:00 表示, 保证与原时刻严格相同
DEADLINE_CN=$(python3 -c "
from datetime import datetime, timezone, timedelta
utc = datetime.fromisoformat('$DEADLINE'.replace('Z', '+00:00'))
print(utc.astimezone(timezone(timedelta(hours=8))).isoformat())")
code=$(curl -s -o /tmp/dl_retry_resp.json -w '%{http_code}' -X POST "$BASE/review-deadline" -H "$ORG" \
  -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"$DEADLINE_CN\"}")
cat /tmp/dl_retry_resp.json \
  | j "{'changed': d['changed'], 'deadline_at': d['review_deadline']['deadline_at']}"
echo "    HTTP $code (请求时刻 $DEADLINE_CN)"

echo "== 7. 同版异值重试 (即使该异值是未来时刻) -> 409, 原截止不覆盖 =="
OTHER=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(days=1)).isoformat().replace("+00:00","Z"))')
curl -s -o /dev/null -w '    同版异值 -> HTTP %{http_code}\n' -X POST "$BASE/review-deadline" \
  -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"$OTHER\"}"

echo "== 8. 其余既有判定不变 =="
curl -s -o /dev/null -w '    发布序号不符 -> HTTP %{http_code} (409)\n' -X POST "$BASE/review-deadline" \
  -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $((SER+1)), \"deadline_at\": \"$OTHER\"}"
curl -s -o /dev/null -w '    修订号不符   -> HTTP %{http_code} (409)\n' -X POST "$BASE/review-deadline" \
  -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $((REV+1)), \"base_serial\": $SER, \"deadline_at\": \"$OTHER\"}"
curl -s -o /dev/null -w '    无时区时刻   -> HTTP %{http_code} (422)\n' -X POST "$BASE/review-deadline" \
  -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"2026-10-04T09:00:00\"}"
curl -s -o /dev/null -w '    非法时刻     -> HTTP %{http_code} (422)\n' -X POST "$BASE/review-deadline" \
  -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV, \"base_serial\": $SER, \"deadline_at\": \"not-a-time\"}"

echo "== 9. 幂等重试未写新记录、未推进 revision/serial =="
curl -s "$BASE/meta" -H "$ORG" | j "{'revision': d['revision'], 'serial': d['published']['serial'], 'deadline': d['review_deadline']['deadline_at']}"
echo "    (revision 应仍为 $REV, serial 应仍为 $SER, 截止为第 3 步原值)"
