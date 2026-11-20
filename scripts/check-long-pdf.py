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
    default = paid if selection_check else subscription
    cancel_polls = 0
    with listener.accept()[0] as conn, conn.makefile("rwb") as wire:
        for line in wire:
            request = json.loads(line)
            action = request["action"]
            result = {"ok": True, "id": request["id"]}
            if action == "capabilities":
                result.update(protocolVersion=1, commandSocket=True,
                              supports=["conversation", "researchContext", "researchPrompt", "researchMaterial", "modelCatalog", "researchSelectModel"],
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
                assert request["selection"] in (subscription, paid)
                selected[request["sessionId"]] = result["selected"] = request["selection"]
            elif action == "researchPrompt":
                assert request["selection"] == selected[request["sessionId"]]
                deliberate = selection_check and request["material"]["source"] == "Fixture explicit paid choice"
                assert request["selection"] == (paid if deliberate else subscription), "Unexpected paid translation or prompt"
                history = replies[request["sessionId"]]
                result["selection"] = request["selection"]
                material = dict(request["material"])
                assert set(material) <= {"source", "title", "scope", "text", "page"}
                assert len(material["text"].encode("utf-16-le")) // 2 <= 24_000
                assert request["includeContext"] and request["sessionId"] in sessions
                question = request["text"]
                if "FAIL_SEGMENT" in question and "第 2/" in question:
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
            worker = threading.Thread(target=serve, args=(listener, path, selection_check), daemon=True)
            worker.start()
            # This existing diagnostic switch prevents writes to the installed app's launch log.
            subprocess.run([verifier, root, "--check-bridge"], check=True)
