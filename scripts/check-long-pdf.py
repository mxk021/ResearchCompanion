"""Run the native PDF/client check against a simulated local command socket."""
import json
import os
import platform
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

def serve(listener, path, selection_check):
    sessions, replies = [], {}
    selected = {}
    reasoning = {"efforts": [{"id": "low", "name": "Low"}], "defaultEffort": "low"}
    subscription = dict(provider="chatgpt", model="gpt-6.2-sol", reasoningEffort="low")
    paid = dict(provider="deepseek-account", model="fixture-paid")
    # A newly created session reports the requested tuple before the provider
    # resolves its default effort. Planning and answering must use the same resolved tuple.
    default = paid if selection_check else dict(provider=subscription["provider"], model=subscription["model"])
    range_packets = []
    cancel_polls = 0
    rejected_part = False
    first_part_requests = 0
    plan_steps = {}
    semantic = "为什么两次记录各用一种代号？"
    cold_question = "有什么要留意的？"
    inferred_range = "开场是 OPENING THISTLE，收尾是 PAGE_1_END，两处之间都要译成中文。"
    with listener.accept()[0] as conn, conn.makefile("rwb") as wire:
        for line in wire:
            request = json.loads(line)
            action = request["action"]
            result = {"ok": True, "id": request["id"]}
            if action == "capabilities":
                result.update(protocolVersion=1, commandSocket=True,
                              supports=["conversation", "researchContext", "researchPrompt", "researchMaterial", "modelCatalog", "researchSelectModel", "researchDocumentPlan"],
                              instance=dict(instanceId="pdf-check", commandSocketPath=str(path), statusSocketPath=str(path) + "-status"))
            elif action == "workspaces":
                result["workspaces"] = [dict(id="pdf", title="PDF fixture", path=str(path.parent),
                                             status="ready", sessionIds=sessions)]
            elif action == "createSession":
                result["sessionId"] = request["sessionId"]
                sessions.append(request["sessionId"])
                selected[request["sessionId"]] = default
                replies[request["sessionId"]] = []
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
                route = request["selection"]
                session = request["sessionId"]
                assert request["workspaceId"] == "pdf" and session in sessions
                assert route == selected[session] == subscription and doc["pages"] == (1 if q == cold_question else 52)
                assert "originalPath" not in doc and "bookmark" not in doc and len(doc["id"]) == 64
                stamp = (session, doc["id"], route["provider"], route["model"], route["reasoningEffort"])
                previous = plan_steps.setdefault(q, [])
                assert len(previous) < 2 and all(item == stamp for item in previous)
                assert ("feedback" in doc) == bool(previous)
                if previous:
                    assert doc["feedback"].startswith("【已读取的证据】") == (q != "这行代号怎么理解？")
                if q == cold_question:
                    assert not previous
                    plan = {"action": "pages", "pageStart": 1, "pageEnd": 1}
                elif q == semantic:
                    if previous:
                        assert "OPENING THISTLE" in doc["feedback"]
                    plan = {"action": "search", "query": "FINAL QUARTZ" if previous else "OPENING THISTLE"}
                elif q == inferred_range:
                    assert not previous
                    plan = {"action": "range", "start": "OPENING THISTLE", "end": "PAGE_1_END"}
                elif q == "HYPERION":
                    plan = {"action": "useEvidence"} if previous else {"action": "search", "query": q}
                elif q == "结合论文解释这段":
                    assert doc["selection"] == "LARCH: fresh preview"
                    plan = {"action": "useEvidence"} if previous else {"action": "combined", "query": "MIDPOINT LARCH"}
                elif q == "这行代号怎么理解？":
                    plan = {"action": "search", "query": "nonexistentfixturemark"}
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
                history = replies[request["sessionId"]]
                result["selection"] = request["selection"]
                material = dict(request["material"])
                assert set(material) <= {"source", "title", "scope", "text", "page"}
                assert len(material["text"].encode("utf-16-le")) // 2 <= 24_000
                assert request["includeContext"] and request["sessionId"] in sessions
                question = request["text"]
                if question in plan_steps:
                    assert len(plan_steps[question]) == (1 if question in (inferred_range, cold_question) else 2)
                    assert all(step[0] == request["sessionId"] and step[2:] ==
                               (request["selection"]["provider"], request["selection"]["model"], request["selection"]["reasoningEffort"])
                               for step in plan_steps[question])
                if "FAIL_SEGMENT" in question and "第 1/" in question:
                    first_part_requests += 1
                    assert first_part_requests == 1, "Retry submitted a completed chunk twice"
                if "FAIL_SEGMENT" in question and "第 2/" in question and not rejected_part:
                    rejected_part = True
                    result.update(ok=False, error={"code": "fixture/rejected", "message": "synthetic rejection"})
                else:
                    material.update(key="fixturekey")
                    reply = dict(question=question, questionId="u" + str(len(history)),
                                 requestId=request["requestId"], material=material)
                    history.append(dict(id="a" + str(len(history)), role="assistant", text="Synthetic reply.", reply=reply))
                    result["accepted"] = True
                    if "CANCEL_SEGMENT" in question:
                        cancel_polls = 1
            elif action == "conversation":
                result.update(messages=replies[request["sessionId"]], running=cancel_polls > 0, selection=selected[request["sessionId"]])
                cancel_polls = max(0, cancel_polls - 1)
            elif action != "subscribe":
                raise ValueError(action)
            wire.write(json.dumps(result, ensure_ascii=False).encode() + b"\n")
            wire.flush()

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
