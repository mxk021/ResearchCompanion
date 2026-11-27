"""Run the native PDF/client check against a simulated local command socket."""
import json
import os
import platform
import re
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

def serve(listener, path, selection_check):
    sessions, replies = [], {}
    completed_parts, translations, batches = {}, {}, {}
    selected = {}
    reasoning = {"efforts": [{"id": "low", "name": "Low"}], "defaultEffort": "low"}
    subscription = dict(provider="chatgpt", model="gpt-6.2-sol", reasoningEffort="low")
    paid = dict(provider="deepseek-account", model="fixture-paid")
    # A newly created session reports the requested tuple before the provider
    # resolves its default effort. Planning and answering must use the same resolved tuple.
    default = paid if selection_check else dict(provider=subscription["provider"], model=subscription["model"])
    range_packets = []
    grid_requests = 0
    grid_excerpt = "结合选区解释论文第1页的观测"
    grid_combined = grid_excerpt + "依据，必须完整核对该页原文。"
    grid_cancelled = grid_excerpt + "含义，必须完整核对该页原文。"
    cancel_polls = 0
    rejected_part = False
    first_part_requests = 0
    incomplete_ack_id = None
    recovered_ack = False
    plan_steps = {}
    cold_question = "有什么要留意的？"
    local_questions = {cold_question, "HYPERION", "请总结这篇论文的主要贡献。", "它有哪些局限？"}
    local_calls = []
    long_range = "请把从 OPENING THISTLE 到 PAGE_52_END 的原文逐段翻译成中文。"
    exact_parts = None
    inferred_range = "开场是 OPENING THISTLE，收尾是 PAGE_1_END，两处之间都要译成中文。"
    with listener.accept()[0] as conn, conn.makefile("rwb") as wire:
        for line in wire:
            request = json.loads(line)
            action = request["action"]
            result = {"ok": True, "id": request["id"]}
            if action == "capabilities":
                result.update(protocolVersion=1, commandSocket=True,
                              supports=["conversation", "researchContext", "researchPrompt", "researchMaterial", "modelCatalog",
                                        "researchSelectModel", "researchDocumentPlan", "researchPromptGuidance", "researchPdfBatch"],
                              instance=dict(instanceId="pdf-check", commandSocketPath=str(path), statusSocketPath=str(path) + "-status"))
            elif action == "workspaces":
                result["workspaces"] = [dict(id="pdf", title="PDF fixture", path=str(path.parent),
                                             status="ready", sessionIds=sessions)]
            elif action == "createSession":
                result["sessionId"] = request["sessionId"]
                sessions.append(request["sessionId"])
                selected[request["sessionId"]] = default
                replies[request["sessionId"]] = []
                completed_parts[request["sessionId"]] = {}
            elif action == "modelCatalog":
                result["catalog"] = dict(defaultSelection=default, groups=[
                    dict(id="chatgpt", name="Subscription", models=[dict(id=subscription["model"], name="Sol", reasoning=reasoning)]),
                    dict(id="deepseek-account", name="Paid", models=[dict(id=paid["model"], name="Paid")])])
            elif action == "researchSelectModel":
                assert request["workspaceId"] == "pdf" and request["sessionId"] in sessions
                assert request["selection"] in (subscription, paid, default)
                resolved = subscription if not selection_check and request["selection"] == default else request["selection"]
                selected[request["sessionId"]] = result["selected"] = resolved
            elif action == "researchDocumentPlan":
                # Unknown planning requests include strict-selection and exact-range paths:
                # these must never expose even the file outline to the model.
                q, doc = request["text"], request["document"]
                assert q not in local_questions, "Ordinary paper summary and follow-up must use local evidence first"
                route = request["selection"]
                session = request["sessionId"]
                assert request["workspaceId"] == "pdf" and session in sessions
                assert route == selected[session] == subscription and doc["pages"] == 52
                assert "originalPath" not in doc and "bookmark" not in doc and len(doc["id"]) == 64
                stamp = (session, doc["id"], route["provider"], route["model"], route["reasoningEffort"])
                previous = plan_steps.setdefault(q, [])
                assert len(previous) < 2 and all(item == stamp for item in previous)
                assert ("feedback" in doc) == bool(previous)
                if previous:
                    assert doc["feedback"].startswith("【已读取的证据】")
                if q == inferred_range:
                    assert not previous
                    plan = {"action": "range", "start": "OPENING THISTLE", "end": "PAGE_1_END"}
                elif q == "结合论文解释这段":
                    assert doc["selection"] == "LARCH: fresh preview"
                    plan = {"action": "useEvidence"} if previous else {"action": "combined", "query": "MIDPOINT LARCH"}
                else:
                    raise AssertionError("Unexpected model planning request: " + q)
                previous.append(stamp)
                result.update(selection=route, documentId=doc["id"], plan=plan)
            elif action == "researchPrompt":
                assert request["selection"] == selected[request["sessionId"]]
                deliberate = selection_check and request["material"]["source"] == "Fixture explicit paid choice"
                if not selection_check and request["text"] == "翻译从 OPENING THISTLE 到 PAGE_1_END 的内容。":
                    deliberate = request["selection"] == paid
                    packet = request["material"]
                    range_packets.append(packet)
                    assert all(first == packet for first in range_packets)
                assert request["selection"] == (paid if deliberate else subscription), "Unexpected paid translation or prompt"
                session = request["sessionId"]
                history = replies[session]
                result["selection"] = request["selection"]
                material = dict(request["material"])
                assert set(material) <= {"source", "title", "scope", "text", "page"}
                assert len(material["text"].encode("utf-16-le")) // 2 <= 24_000
                assert request["includeContext"] and request["sessionId"] in sessions
                question = request["text"]
                guidance = request.get("guidance")
                assert guidance is None or (0 < len(guidance.encode("utf-16-le")) // 2 <= 6000 and guidance not in question)
                assert "【本轮仅有部分证据】" not in question and not re.search(r"第 [0-9]+/", question)
                batch = request.get("pdfBatch")
                stage = batch["stage"] if batch else None
                if batch:
                    assert not selection_check and guidance
                    assert set(batch) <= {"id", "stage", "index", "count"}
                    assert re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", batch["id"], re.I)
                    assert stage in ("work", "translation", "result")
                    part, count = batch.get("index"), batch.get("count")
                    assert (part is None and count is None and stage != "translation") or 1 <= part <= count <= 40
                    key = session, batch["id"]
                    assert batches.setdefault(key, question) == question, "Internal steps must preserve the original visible question"
                if question in local_questions:
                    assert stage is None and question not in local_calls, "Each local summary or follow-up must admit one request"
                    local_calls.append(question)
                if question == long_range:
                    if exact_parts is None:
                        exact_parts = json.loads((path.parent / "expected-long-exact.json").read_text())
                    assert stage == "translation" and count == len(exact_parts)
                    assert material["text"] == exact_parts[part - 1], "The exact range changed at the wire boundary"
                if "已有的有效证据" in question:
                    assert guidance and "本轮仅有部分证据" in guidance and "第 2 页" in guidance
                    assert "PAGE_1_START" in material["text"] and "PAGE_2_START" not in material["text"]
                if "用户修正并核验" in material.get("scope", ""):
                    assert guidance and "ABSENT" not in guidance
                    if "CANCEL_SEGMENT" in question:
                        assert question == "CANCEL_SEGMENT 请把从 OPENING THISTLE 到 ABSENT BATCH TERMINAL 的原文逐段翻译成中文。"
                        assert "PAGE_52_END" in guidance
                    else:
                        assert question == "请把从 OPENING THISTLE 到 ABSENT TERMINAL 的原文逐段翻译成中文。"
                        assert "PAGE_1_END" in guidance
                if selection_check:
                    retry_fixture = question == "只用选区，指出这句话的主语。"
                    if material["source"] == "Explicit mode fixture":
                        assert request["mode"] == ("ask" if retry_fixture else "explain")
                    else:
                        assert request["mode"] == "translate"
                    if retry_fixture:
                        if incomplete_ack_id is None:
                            incomplete_ack_id = request["requestId"]
                            wire.write(json.dumps({**result, "accepted": False}).encode() + b"\n")
                            wire.flush()
                            continue
                        assert not recovered_ack and request["requestId"] == incomplete_ack_id
                        recovered_ack = True
                if question == "翻译从 West observation 0 到 East observation 2 的内容。":
                    grid_requests += 1
                    assert grid_requests == 1 and "经用户对照" in material["scope"]
                    assert "West observation 0" in material["text"] and "East observation 2" in material["text"]
                    cell = r"(?:West|Center|East) observation [0-2]"
                    wanted = sorted(f"{side} observation {row}" for side in ["West", "Center", "East"] for row in range(3))
                    assert sorted(re.findall(cell, material["text"])) == wanted
                    assert not re.sub(cell, "", material["text"]).strip(), "The candidate included text outside the grid"
                assert question != grid_cancelled, "A declined proposal must not be submitted"
                if question == grid_combined:
                    assert "经用户对照" in material["scope"] and "My current excerpt" in material["text"]
                if question in plan_steps:
                    assert len(plan_steps[question]) == (1 if question == inferred_range else 2)
                    assert all(step[0] == request["sessionId"] and step[2:] ==
                               (request["selection"]["provider"], request["selection"]["model"], request["selection"]["reasoningEffort"])
                               for step in plan_steps[question])
                if "FAIL_SEGMENT" in question and stage == "work" and part == 1:
                    first_part_requests += 1
                    assert first_part_requests == 1, "Retry submitted a completed chunk twice"
                if "FAIL_SEGMENT" in question and stage == "work" and part == 2 and not rejected_part:
                    rejected_part = True
                    result.update(ok=False, error={"code": "fixture/rejected", "message": "synthetic rejection"})
                else:
                    request_id = request["requestId"]
                    material.update(key="fixturekey")
                    question_id = "u-" + request_id
                    reply = dict(question=question, questionId=question_id, requestId=request_id, material=material)
                    answer = dict(id="a-" + request_id, role="assistant", text="Synthetic reply.", reply=reply)
                    if stage in ("work", "translation"):
                        answer["text"] = f"Synthetic {stage} part {part}."
                    if batch:
                        parts = completed_parts[session]
                        assert request_id not in parts
                        parts[request_id] = dict(requestId=request_id, text=answer["text"])
                    if stage == "translation":
                        public_id = "pdf-" + batch["id"]
                        if key not in translations:
                            answer["id"] = public_id
                            history.append(dict(id=public_id, role="user", text=question, plainQuestion=True))
                            history.append(answer)
                            translations[key] = answer, {}
                        displayed, parts = translations[key]
                        assert part == len(parts) + 1, "Translation chunks arrived out of order or were duplicated"
                        parts[part] = f"Synthetic translation part {part}."
                        displayed["text"] = "\n\n".join(parts.values())
                        if len(parts) < count:
                            displayed["text"] += f"\n\n已取得 {len(parts)}/{count} 段翻译。"
                    elif stage != "work":
                        if stage == "result":
                            assert "Synthetic work part" in guidance and "Synthetic work part" not in material["text"]
                        if not selection_check:
                            history.append(dict(id=question_id, role="user", text=question, plainQuestion=True))
                        history.append(answer)
                    result["accepted"] = True
                    if "CANCEL_SEGMENT" in question:
                        cancel_polls = 1
            elif action == "conversation":
                session = request["sessionId"]
                result.update(messages=replies[session], running=cancel_polls > 0, selection=selected[session])
                if cancel_polls == 0:
                    completed = completed_parts[session].get(request.get("requestId"))
                    if completed:
                        result["completedPart"] = completed
                if "requestId" not in request:
                    cancel_polls = max(0, cancel_polls - 1)
            elif action != "subscribe":
                raise ValueError(action)
            wire.write(json.dumps(result, ensure_ascii=False).encode() + b"\n")
            wire.flush()
    if not selection_check:
        assert grid_requests == 1, "Only the current, confirmed candidate may reach the provider."
        assert set(local_calls) == local_questions, "Expected local-only summary, follow-up, vague and lexical turns"
    else:
        assert recovered_ack, "The incomplete acknowledgement was not retried with the saved request id."

if __name__ == "__main__":
    project = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="rc-pdf-", dir="/private/tmp") as tmp:
        root = Path(tmp)
        selection_check = sys.argv[1:] == ["--selection"]
        if len(sys.argv) == 2 and not selection_check:
            verifier = Path(sys.argv[1]).resolve()
        else:
            verifier = root / "check"
            sources = sorted((project / "Sources/DSHPet").glob("*.swift"))
            sources = [p for p in sources if p.name != "DSHPetMain.swift"]
            sdk = os.environ.get("SDKROOT") or subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            sdk_args = ["-sdk", sdk]
            check = "check-selection.swift" if selection_check else "check-long-pdf.swift"
            subprocess.run(["swiftc", *sdk_args, "-target", f"{platform.machine()}-apple-macos14.0", "-parse-as-library", "-module-cache-path", root / "modules", *sources,
                            project / "scripts" / check, "-o", verifier], check=True)
        path = root / "wire.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            listener.listen()
            failures = []
            def observe_socket():
                try:
                    serve(listener, path, selection_check)
                except Exception as error:
                    failures.append(error)
            worker = threading.Thread(target=observe_socket, daemon=True)
            worker.start()
            # This existing diagnostic switch prevents writes to the installed app's launch log.
            result = subprocess.run([verifier, root, "--check-bridge"])
            worker.join(timeout=3)
            if failures:
                raise failures[0]
            result.check_returncode()
            if worker.is_alive():
                raise RuntimeError("The synthetic client did not close its socket")
