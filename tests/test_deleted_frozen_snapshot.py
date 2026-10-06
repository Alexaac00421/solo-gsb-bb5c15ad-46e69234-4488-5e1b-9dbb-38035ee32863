"""本轮功能测试: 删除冻结序号上不得签发作者反馈快照。

修复的缺陷: 旧发布版两名评审人已确认并交评语、删除前从未发布反馈快照时,
删除并同编号录入新稿后, 按当前 (删除凭据冻结的) 发布序号请求反馈快照会用
旧收据生成新访问码, 使持码者读到旧稿评语。

覆盖:
- 删除冻结序号 (同编号重录未重新发布 / 删除后未重录) 请求快照 -> 404,
  不生成版本或访问码, 不推进资料修订号; 历史记录仍供会务方追溯;
- 删除前已发过快照时, 同序号同收据重发仍按既有约定 409 (不返回旧码);
- 旧访问码在删除后/重录后/重新发布后持续 404 (与无效码同形);
- 恢复路径: 重新发布分配 (序号推进) -> 新序号重新确认并交齐两份评语 ->
  可发布快照 (新版本 + 新访问码, 持码可读); 新序号不齐仍 422;
- 冻结序号不符的既有 409 优先级不变; 冻结按论文隔离, 同序号他稿照常发布;
- 多次 删除->重录 循环: 每个冻结序号均拒绝, 重新发布后恢复;
- 迁移: 伪造"删除冻结序号上的有效快照" (创建时刻晚于删除时刻) 恢复 422
  且不留部分数据; 合法的 删除->重录->重新发布->新快照 回环可恢复,
  恢复快照后新码活、旧码死。
"""
import copy
import os
import tempfile

_TMPDIR = tempfile.mkdtemp(prefix="review-deleted-frozen-snapshot-test-")
os.environ["DB_PATH"] = os.path.join(_TMPDIR, "test.db")
os.environ["ORGANIZER_KEY"] = "test-organizer-key"

import pytest
from fastapi.testclient import TestClient

from app import db, migration
from app.main import app

ORG = {"X-Organizer-Key": "test-organizer-key"}


@pytest.fixture(autouse=True)
def clean_db():
    db.reset_for_tests()
    with db.write_txn() as conn:
        for table in migration.BUSINESS_TABLES + ("migration_restores",):
            conn.execute(f"DELETE FROM {table}")
        conn.execute("UPDATE meta SET value = '0' WHERE key = 'revision'")
    yield


@pytest.fixture
def client():
    return TestClient(app)


def reviewer_headers(rid):
    return {"X-Reviewer-Id": rid, "X-Reviewer-Credential": f"cred-{rid}"}


def add_reviewer(client, rid, institution=None, capacity=3, topics=None):
    return client.post(
        "/reviewers",
        headers=ORG,
        json={
            "reviewer_id": rid,
            "credential": f"cred-{rid}",
            "topics": topics if topics is not None else ["AI"],
            "institution": institution or f"Inst-{rid}",
            "capacity": capacity,
            "avoid_papers": [],
        },
    )


def add_paper(client, pid="P1", topics=None, institutions=None, manuscript=None):
    return client.post(
        "/papers",
        headers=ORG,
        json={
            "paper_id": pid,
            "manuscript": manuscript if manuscript is not None else f"manuscript-of-{pid}",
            "topics": topics if topics else ["AI"],
            "institutions": institutions if institutions else [f"Author-{pid}"],
        },
    )


def current_revision(client):
    return client.get("/meta", headers=ORG).json()["revision"]


def publish(client):
    rev = client.post("/assignment/dry-run", headers=ORG).json()["revision"]
    r = client.post("/assignment/publish", headers=ORG, json={"base_revision": rev})
    assert r.status_code == 200, r.text
    return r.json()


def decide(client, rid, pid, decision="confirm"):
    r = client.post(
        f"/reviewer/assignments/{pid}/decision",
        headers=reviewer_headers(rid),
        json={"paper_id": pid, "decision": decision},
    )
    assert r.status_code == 200, r.text
    return r.json()


def submit_review(client, rid, pid, serial, score=4, comment=None):
    r = client.post(
        f"/reviewer/assignments/{pid}/review",
        headers=reviewer_headers(rid),
        json={
            "paper_id": pid, "serial": serial, "score": score,
            "comment": comment or f"评语-{rid}-{pid}",
        },
    )
    assert r.status_code == 200, r.text
    return r.json()


def setup_published_paper(client, pid="P1", reviewers=("R1", "R2")):
    """录入评审人与论文, 发布, 两评审人确认并交评语 (不发快照); 返回 (serial, receipts)。"""
    for rid in reviewers:
        assert add_reviewer(client, rid).status_code == 201
    assert add_paper(client, pid).status_code == 201
    serial = publish(client)["serial"]
    receipts = []
    for rid, score in zip(reviewers, (4, 5)):
        decide(client, rid, pid, "confirm")
        receipts.append(
            submit_review(client, rid, pid, serial, score=score)["receipt"]
        )
    return serial, receipts


def snapshot_request(client, pid, serial):
    return client.post(
        f"/papers/{pid}/feedback-snapshot", headers=ORG, json={"serial": serial}
    )


def snapshot_versions(client, pid):
    return client.get(f"/papers/{pid}/feedback-snapshots", headers=ORG).json()["snapshots"]


# ------------------------------------------------------------ 缺陷核心: 冻结序号拒发快照

def test_frozen_serial_snapshot_rejected_after_delete_and_reentry(client):
    """删除前从未发布快照: 删除 + 同编号重录 (未重新发布) 后,
    按当前 (冻结) 序号请求快照 -> 404, 不生成版本/访问码, 不推进修订号。"""
    serial, _ = setup_published_paper(client)
    assert client.delete("/papers/P1", headers=ORG).status_code == 200
    assert add_paper(client, "P1", manuscript="重录新稿").status_code == 201

    rev_before = current_revision(client)
    r = snapshot_request(client, "P1", serial)
    assert r.status_code == 404
    assert "删除" in r.json()["detail"]
    # 不生成版本或访问码, 不改变资料修订号
    assert snapshot_versions(client, "P1") == []
    assert current_revision(client) == rev_before


def test_frozen_serial_snapshot_rejected_before_reentry(client):
    """删除后、同编号重录前同样拒绝 (历史槽位仍冻结在该序号)。"""
    serial, _ = setup_published_paper(client)
    assert client.delete("/papers/P1", headers=ORG).status_code == 200

    rev_before = current_revision(client)
    r = snapshot_request(client, "P1", serial)
    assert r.status_code == 404
    assert snapshot_versions(client, "P1") == []
    assert current_revision(client) == rev_before


def test_frozen_serial_rejection_is_per_paper(client):
    """冻结按论文隔离: 同序号下未删除的他稿照常发布快照。"""
    for rid in ("R1", "R2", "R3", "R4"):
        assert add_reviewer(client, rid).status_code == 201
    assert add_paper(client, "P1").status_code == 201
    assert add_paper(client, "P2").status_code == 201
    serial = publish(client)["serial"]
    plan = client.get("/assignment", headers=ORG).json()["plan"]
    for pid in ("P1", "P2"):
        for rid in plan[pid]:
            decide(client, rid, pid, "confirm")
            submit_review(client, rid, pid, serial)

    assert client.delete("/papers/P1", headers=ORG).status_code == 200
    assert add_paper(client, "P1", manuscript="重录新稿").status_code == 201

    # P1 冻结 -> 404; P2 未删除 -> 照常发布, 持码可读
    assert snapshot_request(client, "P1", serial).status_code == 404
    ok = snapshot_request(client, "P2", serial)
    assert ok.status_code == 200, ok.text
    code = ok.json()["access_code"]
    assert client.get(f"/feedback-snapshots/{code}").status_code == 200


def test_serial_mismatch_still_409_precedence(client):
    """序号过期/超前的既有 409 约定不变 (先于冻结判定)。"""
    serial, _ = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    r = snapshot_request(client, "P1", serial + 1)
    assert r.status_code == 409
    assert snapshot_versions(client, "P1") == []


def test_same_receipts_republish_after_deletion_still_409(client):
    """删除前已发过快照: 同序号同收据重发仍按既有约定 409 (不返回旧码、
    不覆盖历史版本行), 旧码持续 404。"""
    serial, _ = setup_published_paper(client)
    old = snapshot_request(client, "P1", serial).json()
    old_code = old["access_code"]
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")

    r = snapshot_request(client, "P1", serial)
    assert r.status_code == 409
    assert client.get(f"/feedback-snapshots/{old_code}").status_code == 404
    versions = snapshot_versions(client, "P1")
    assert len(versions) == 1 and versions[0]["access_code"] == old_code
    assert versions[0]["active"] is False


# ------------------------------------------------------------ 恢复路径: 重新发布 -> 新序号重确认重交

def test_republish_reconfirm_then_snapshot_succeeds(client):
    """重新发布分配 (序号推进) 后, 两名评审人在新序号重新确认并交齐评语,
    才能为重录稿发布快照: 新版本 + 新访问码, 内容为重录后的新评语。"""
    serial, old_receipts = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    assert snapshot_request(client, "P1", serial).status_code == 404

    new_serial = publish(client)["serial"]
    assert new_serial == serial + 1
    decide(client, "R1", "P1", "confirm")
    decide(client, "R2", "P1", "confirm")
    new_receipts = [
        submit_review(client, "R1", "P1", new_serial, score=3, comment="重录稿评语 R1")["receipt"],
        submit_review(client, "R2", "P1", new_serial, score=2, comment="重录稿评语 R2")["receipt"],
    ]
    assert set(new_receipts) != set(old_receipts)

    ok = snapshot_request(client, "P1", new_serial)
    assert ok.status_code == 200, ok.text
    body = ok.json()
    assert body["version"] == 1 and body["changed"] is True
    code = body["access_code"]
    read = client.get(f"/feedback-snapshots/{code}")
    assert read.status_code == 200
    comments = {r["comment"] for r in read.json()["reviews"]}
    assert comments == {"重录稿评语 R1", "重录稿评语 R2"}
    versions = snapshot_versions(client, "P1")
    assert len(versions) == 1 and versions[0]["active"] is True


def test_new_serial_incomplete_material_still_422(client):
    """重新发布后新序号下确认/评语未齐 -> 既有 422 约定不变, 不留新版本。"""
    serial, _ = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    new_serial = publish(client)["serial"]
    decide(client, "R1", "P1", "confirm")
    submit_review(client, "R1", "P1", new_serial, comment="重录稿评语 R1")
    # R2 未确认未交 -> 422; 另一情形: 两人确认但只交一份 -> 422
    r = snapshot_request(client, "P1", new_serial)
    assert r.status_code == 422
    decide(client, "R2", "P1", "confirm")
    r = snapshot_request(client, "P1", new_serial)
    assert r.status_code == 422
    assert snapshot_versions(client, "P1") == []


def test_old_code_stays_dead_across_reentry_and_republish(client):
    """旧访问码在删除后、重录后、重新发布后持续 404 (与无效码同形);
    新序号重发快照生成新码, 新码可读。"""
    serial, _ = setup_published_paper(client)
    old_code = snapshot_request(client, "P1", serial).json()["access_code"]
    client.delete("/papers/P1", headers=ORG)
    assert client.get(f"/feedback-snapshots/{old_code}").status_code == 404
    add_paper(client, "P1", manuscript="重录新稿")
    assert client.get(f"/feedback-snapshots/{old_code}").status_code == 404
    new_serial = publish(client)["serial"]
    assert client.get(f"/feedback-snapshots/{old_code}").status_code == 404
    decide(client, "R1", "P1", "confirm")
    decide(client, "R2", "P1", "confirm")
    submit_review(client, "R1", "P1", new_serial, comment="重录稿评语 R1")
    submit_review(client, "R2", "P1", new_serial, comment="重录稿评语 R2")
    new_code = snapshot_request(client, "P1", new_serial).json()["access_code"]
    assert new_code != old_code
    assert client.get(f"/feedback-snapshots/{new_code}").status_code == 200
    r_old = client.get(f"/feedback-snapshots/{old_code}")
    r_bogus = client.get("/feedback-snapshots/fbk-0000deadbeef")
    assert r_old.status_code == r_bogus.status_code == 404
    assert r_old.json() == r_bogus.json()


def test_multiple_delete_reentry_cycles_each_frozen_serial_rejected(client):
    """多次 删除->重录: 每个被删除凭据冻结的序号都拒绝签发, 重新发布后恢复。"""
    serial1, _ = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录稿 v2")
    serial2 = publish(client)["serial"]
    decide(client, "R1", "P1", "confirm")
    decide(client, "R2", "P1", "confirm")
    submit_review(client, "R1", "P1", serial2, comment="v2 评语 R1")
    submit_review(client, "R2", "P1", serial2, comment="v2 评语 R2")
    # 第二次删除 (未发过快照) + 重录, 不重新发布
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录稿 v3")

    rev_before = current_revision(client)
    r = snapshot_request(client, "P1", serial2)
    assert r.status_code == 404
    assert snapshot_versions(client, "P1") == []
    assert current_revision(client) == rev_before

    # 重新发布 (serial3) -> 重新确认交齐 -> 可发
    serial3 = publish(client)["serial"]
    assert serial3 == serial2 + 1
    decide(client, "R1", "P1", "confirm")
    decide(client, "R2", "P1", "confirm")
    submit_review(client, "R1", "P1", serial3, comment="v3 评语 R1")
    submit_review(client, "R2", "P1", serial3, comment="v3 评语 R2")
    ok = snapshot_request(client, "P1", serial3)
    assert ok.status_code == 200, ok.text
    assert client.get(f"/feedback-snapshots/{ok.json()['access_code']}").status_code == 200


def test_history_remains_traceable_for_organizer(client):
    """拒绝签发不影响会务方追溯: 删除凭据、快照版本列表、评语进度照常可查。"""
    serial, _ = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    assert snapshot_request(client, "P1", serial).status_code == 404

    dels = client.get("/papers/P1/deletions", headers=ORG).json()["deletions"]
    assert len(dels) == 1 and dels[0]["published_serial"] == serial
    assert client.get("/papers/P1/feedback-snapshots", headers=ORG).status_code == 200
    reviews = client.get("/papers/P1/reviews", headers=ORG)
    assert reviews.status_code == 200


# ------------------------------------------------------------ 迁移: 冻结序号上的"有效"快照不得恢复

def export_snapshot(client):
    r = client.get("/migration/export", headers=ORG)
    assert r.status_code == 200, r.text
    return r.json()


def wipe_instance():
    with db.write_txn() as conn:
        for table in migration.BUSINESS_TABLES + ("migration_restores",):
            conn.execute(f"DELETE FROM {table}")
        conn.execute("UPDATE meta SET value = '0' WHERE key = 'revision'")


def restore(client, snapshot):
    return client.post("/migration/restore", headers=ORG, json=snapshot)


def resign(snapshot):
    snapshot["checksum"] = migration.snapshot_checksum(snapshot["data"])
    return snapshot


def test_restore_rejects_valid_snapshot_on_frozen_serial(client):
    """伪造快照: 删除前从未发过快照, 删除+重录后在导出中注入一行
    "冻结序号上标记有效"的快照 (创建时刻晚于删除时刻, 收据照抄现行评语)
    并重算校验和 -> 恢复 422 (矛盾快照), 目标实例不留部分数据。"""
    serial, receipts = setup_published_paper(client)
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    snap = export_snapshot(client)
    assert snap["format_version"] == 2
    assert snap["data"]["feedback_snapshots"] == []

    forged = copy.deepcopy(snap)
    max_id = max([s["id"] for s in forged["data"]["feedback_snapshots"]], default=0)
    deleted_at = forged["data"]["paper_deletions"][0]["deleted_at"]
    # 创建时刻晚于删除时刻: 仅靠"删除时刻前创建必失效"的旧规则抓不住,
    # 必须靠冻结序号规则拒绝
    created_after = deleted_at[:19] + ".999999" + deleted_at[19:] \
        if "." not in deleted_at[:19] else deleted_at
    forged["data"]["feedback_snapshots"].append(
        {
            "id": max_id + 1,
            "paper_id": "P1",
            "version": 1,
            "serial": serial,
            "receipt1": receipts[0],
            "receipt2": receipts[1],
            "access_code": "fbk-forged-frozen-serial",
            "review1": {"score": 4, "comment": "旧稿评语-R1"},
            "review2": {"score": 5, "comment": "旧稿评语-R2"},
            "created_at": created_after,
            "invalidated": False,
        }
    )
    resign(forged)
    wipe_instance()
    r = restore(client, forged)
    assert r.status_code == 422
    assert "冻结" in r.json()["detail"]
    # 不留部分数据: 目标实例仍为空, 合法快照随后可正常恢复
    assert client.get("/meta", headers=ORG).json()["revision"] == 0
    ok = restore(client, snap)
    assert ok.status_code == 200, ok.text
    # 合法快照恢复后: 冻结序号上仍不得签发 (重录未重新发布)
    assert snapshot_request(client, "P1", serial).status_code == 404


def test_restore_roundtrip_republish_then_snapshot(client):
    """合法回环: 快照 v1 -> 删除 -> 重录 -> 重新发布 -> 新序号重确认重交 ->
    快照 v2; 导出恢复后旧码死、新码活, 冻结序号上的旧版保持失效。"""
    serial, _ = setup_published_paper(client)
    old_code = snapshot_request(client, "P1", serial).json()["access_code"]
    client.delete("/papers/P1", headers=ORG)
    add_paper(client, "P1", manuscript="重录新稿")
    serial2 = publish(client)["serial"]
    decide(client, "R1", "P1", "confirm")
    decide(client, "R2", "P1", "confirm")
    submit_review(client, "R1", "P1", serial2, comment="重录稿评语 R1")
    submit_review(client, "R2", "P1", serial2, comment="重录稿评语 R2")
    new_code = snapshot_request(client, "P1", serial2).json()["access_code"]

    snap = export_snapshot(client)
    wipe_instance()
    r = restore(client, snap)
    assert r.status_code == 200, r.text
    assert client.get(f"/feedback-snapshots/{old_code}").status_code == 404
    assert client.get(f"/feedback-snapshots/{new_code}").status_code == 200
    versions = snapshot_versions(client, "P1")
    assert [v["version"] for v in versions] == [1, 2]
    assert [v["active"] for v in versions] == [False, True]
