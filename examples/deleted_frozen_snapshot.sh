#!/usr/bin/env bash
# 本轮用法端到端示例: 删除冻结序号上不得签发作者反馈快照
#
# 修复的缺陷: 旧发布版两名评审人已确认并交评语、删除前从未发布反馈快照时,
# 删除并同编号录入新稿后, 按当前 (删除凭据冻结的) 发布序号请求反馈快照会用
# 旧收据生成新访问码, 使持码者读到旧稿评语。
#
# 本脚本演示:
#   1) 发布 -> 两评审人确认并交评语 (不发快照) -> 删除 P1 并同编号重录:
#      按冻结序号请求快照 -> 404, 不生成版本/访问码, 资料修订号不变;
#      删除后未重录时同样 404; 历史 (删除凭据/快照版本列表) 仍可追溯;
#   2) 删除前已发过快照的对照: 旧码持续 404, 同序号同收据重发仍 409;
#   3) 恢复路径: 重新发布分配 (序号推进) -> 新序号重新确认并交齐两份评语
#      -> 才能为重录稿发布快照 (新版本 + 新访问码, 持码可读);
#      新序号下确认/评语未齐仍 422; 旧码在新快照发布后依然 404。
#
# 用法: ./examples/deleted_frozen_snapshot.sh [BASE_URL]   (建议对新库运行)
set -euo pipefail

BASE="${1:-http://localhost:8000}"
ORG="X-Organizer-Key: ${ORGANIZER_KEY:-dev-organizer-key}"
j() { python3 -c 'import sys, json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
revision() { curl -s "$BASE/meta" -H "$ORG" | j 'd["revision"]'; }

echo "== 1. 录入 R1/R2 与论文 P1, 发布分配, 两评审人确认并交评语 (不发快照) =="
for spec in 'R1 r1-secret Inst-A' 'R2 r2-secret Inst-B'; do
  set -- $spec
  curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H 'Content-Type: application/json' -d "{
    \"reviewer_id\": \"$1\", \"credential\": \"$2\", \"topics\": [\"AI\"],
    \"institution\": \"$3\", \"capacity\": 3, \"avoid_papers\": []}"
done
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P1", "manuscript": "P1 旧稿全文...", "topics": ["AI"], "institutions": ["Univ-X"]}'
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
SER=$(curl -s -X POST "$BASE/assignment/publish" -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV}" | j 'd["serial"]')
for spec in 'R1 r1-secret 4 旧稿评语-R1' 'R2 r2-secret 2 旧稿评语-R2'; do
  set -- $spec
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/decision" \
    -H "X-Reviewer-Id: $1" -H "X-Reviewer-Credential: $2" \
    -H 'Content-Type: application/json' -d '{"paper_id":"P1","decision":"confirm"}'
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/review" \
    -H "X-Reviewer-Id: $1" -H "X-Reviewer-Credential: $2" \
    -H 'Content-Type: application/json' \
    -d "{\"paper_id\":\"P1\",\"serial\":$SER,\"score\":$3,\"comment\":\"$4\"}"
done
echo "    已发布 serial=$SER, 两名评审人已确认并交评语 (未发布反馈快照)"

echo "== 2. 会务方删除 P1 并同编号重录 (不重新发布分配; 序号仍是被冻结的旧序号) =="
curl -s -X DELETE "$BASE/papers/P1" -H "$ORG" \
  | j '{"revision": d["revision"], "frozen_serial": d["deletion"]["published_serial"], "frozen_plan": d["deletion"]["published_plan"]}'
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P1", "manuscript": "同编号重录新稿", "topics": ["AI"], "institutions": ["Univ-Y"]}'
REV_BEFORE=$(revision)
echo "    重录完成, 当前资料修订号=$REV_BEFORE, 当前发布序号仍为 $SER (冻结)"

echo "== 3. 缺陷修复: 按冻结序号请求反馈快照 -> 404, 不生成版本/访问码, 修订号不变 =="
echo "    POST /papers/P1/feedback-snapshot {serial:$SER} -> HTTP $(curl -s -o /tmp/dfs-resp.json -w '%{http_code}' \
  -X POST "$BASE/papers/P1/feedback-snapshot" -H "$ORG" \
  -H 'Content-Type: application/json' -d "{\"serial\": $SER}") (404)"
python3 -c 'import json; print("   ", json.load(open("/tmp/dfs-resp.json"))["detail"])'
echo "    快照版本列表: $(curl -s "$BASE/papers/P1/feedback-snapshots" -H "$ORG" | j 'd["snapshots"]') (无新版本)"
echo "    资料修订号: $(revision) (与请求前相同, 未推进)"
echo "    删除凭据可追溯:"
curl -s "$BASE/papers/P1/deletions" -H "$ORG" \
  | j '[{"id": x["id"], "published_serial": x["published_serial"], "deleted_at": x["deleted_at"]} for x in d["deletions"]]'

echo "== 4. 对照: 删除前已发过快照时, 旧码持续 404, 同序号同收据重发仍 409 =="
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P2", "manuscript": "P2 匿名稿", "topics": ["AI"], "institutions": ["Univ-Z"]}'
for spec in 'R3 r3-secret Inst-C' 'R4 r4-secret Inst-D'; do
  set -- $spec
  curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H 'Content-Type: application/json' -d "{
    \"reviewer_id\": \"$1\", \"credential\": \"$2\", \"topics\": [\"AI\"],
    \"institution\": \"$3\", \"capacity\": 3, \"avoid_papers\": []}"
done
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
SER2=$(curl -s -X POST "$BASE/assignment/publish" -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV}" | j 'd["serial"]')
PLAN_P2=$(curl -s "$BASE/assignment" -H "$ORG" | j 'd["plan"]["P2"]')
echo "    P2 发布于 serial=$SER2, 槽位 $PLAN_P2"
for rid in $(echo $PLAN_P2 | tr -d "[]',"); do
  cred=$(echo "${rid}-secret" | tr 'A-Z' 'a-z')
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P2/decision" \
    -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred" \
    -H 'Content-Type: application/json' -d '{"paper_id":"P2","decision":"confirm"}'
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P2/review" \
    -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred" \
    -H 'Content-Type: application/json' \
    -d "{\"paper_id\":\"P2\",\"serial\":$SER2,\"score\":4,\"comment\":\"P2 评语-$rid\"}"
done
P2_CODE=$(curl -s -X POST "$BASE/papers/P2/feedback-snapshot" -H "$ORG" \
  -H 'Content-Type: application/json' -d "{\"serial\": $SER2}" | j 'd["access_code"]')
echo "    P2 快照访问码: $P2_CODE (删除前发布)"
curl -s -o /dev/null -X DELETE "$BASE/papers/P2" -H "$ORG"
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P2", "manuscript": "P2 同编号重录稿", "topics": ["AI"], "institutions": ["Univ-Z"]}'
echo "    删除+重录后旧码读取 -> HTTP $(code "$BASE/feedback-snapshots/$P2_CODE") (404, 不复活)"
echo "    同序号同收据重发 -> HTTP $(code -X POST "$BASE/papers/P2/feedback-snapshot" -H "$ORG" \
  -H 'Content-Type: application/json' -d "{\"serial\": $SER2}") (409, 不返回旧码/不覆盖历史)"

echo "== 5. 恢复路径: 重新发布分配 (序号推进), 评审人按新序号重新确认并交齐评语 =="
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
SER3=$(curl -s -X POST "$BASE/assignment/publish" -H "$ORG" -H 'Content-Type: application/json' \
  -d "{\"base_revision\": $REV}" | j 'd["serial"]')
echo "    重新发布: serial=$SER3 (旧序号 $SER 的冻结随之解除约束)"
echo "    新序号下确认/评语未齐 -> HTTP $(code -X POST "$BASE/papers/P1/feedback-snapshot" -H "$ORG" \
  -H 'Content-Type: application/json' -d "{\"serial\": $SER3}") (422, 不产生新版本)"
for spec in 'R1 r1-secret 3 重录稿评语-R1' 'R2 r2-secret 4 重录稿评语-R2'; do
  set -- $spec
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/decision" \
    -H "X-Reviewer-Id: $1" -H "X-Reviewer-Credential: $2" \
    -H 'Content-Type: application/json' -d '{"paper_id":"P1","decision":"confirm"}'
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/review" \
    -H "X-Reviewer-Id: $1" -H "X-Reviewer-Credential: $2" \
    -H 'Content-Type: application/json' \
    -d "{\"paper_id\":\"P1\",\"serial\":$SER3,\"score\":$3,\"comment\":\"$4\"}"
done

echo "== 6. 为重录稿发布快照: 新版本 + 新访问码, 持码读到的是重录后的新评语 =="
curl -s -X POST "$BASE/papers/P1/feedback-snapshot" -H "$ORG" \
  -H 'Content-Type: application/json' -d "{\"serial\": $SER3}" > /tmp/dfs-snap.json
NEW_CODE=$(j 'd["access_code"]' < /tmp/dfs-snap.json)
python3 -c 'import json; d=json.load(open("/tmp/dfs-snap.json"));
print("    version=%s serial=%s access_code=%s" % (d["version"], d["serial"], d["access_code"]))'
curl -s "$BASE/feedback-snapshots/$NEW_CODE" | python3 -m json.tool
curl -s "$BASE/papers/P1/feedback-snapshots" -H "$ORG" \
  | j '[{"version": s["version"], "serial": s["serial"], "active": s["active"]} for s in d["snapshots"]]'

echo "== 演示完成: 冻结序号拒发快照 (404/不留版本/不动修订号), 重新发布+新序号重确认重交后方可签发 =="
