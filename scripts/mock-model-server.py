#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock for repeatable end-to-end runs (no network, no cost). Usage: mock-model-server.py PORT LOGFILE.
Replies are canned by prompt shape: topic analysis, question generation (one question per planned slot), note summaries, tutor/chat.
Every request is appended to LOGFILE as one JSON line {"kind": ...}, so a run can assert exactly how many model calls it made."""
import json, re, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
counter = 0
# Deliberately different constructions, so the app's near-duplicate detector does not flag the mock's questions.
STEMS = ["A lab records {n} independent measurements; which statement about {t} follows from the data?",
         "Which assumption must hold before applying the standard result for {t} in sample {n}?",
         "A student claims a shortcut for {t} in exercise {n}. Which reply is correct?",
         "Identify the quantity that {t} requires when n equals {n}.",
         "For problem {n}, which step first simplifies the {t} setup?",
         "Which interpretation of {t} is consistent with example {n} from lecture?"]

TOPICS = {"topics": [
    {"name": "Estimation", "objectives": ["Derive maximum likelihood estimators"], "sources": [{"document": "notes.txt"}],
     "importance": {"level": "high", "source": "instructor", "weightPercent": 40, "evidence": "Chapter 2 is worth 40% of the exam grade"}},
    {"name": "Maximum likelihood", "parent": "Estimation", "sources": [{"document": "notes.txt"}], "importance": {"level": "medium", "source": "estimated", "evidence": "appears in the worked example"}},
    {"name": "Confidence intervals", "sources": [{"document": "notes.txt"}], "importance": {"level": "low", "source": "unknown", "evidence": ""}}], "structures": []}

def log(kind):
    with open(LOG, "a") as f: f.write(json.dumps({"kind": kind}) + "\n")

def reply(text):
    return {"id": "mock-" + uuid.uuid4().hex[:8], "object": "chat.completion", "model": "scripted-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 100, "completion_tokens": 100, "total_tokens": 200}}

def questions(user):
    global counter
    rid = (re.search(r"req-[0-9a-f-]+", user) or [""])[0] if re.search(r"req-[0-9a-f-]+", user) else ""
    qs = []
    for m in re.finditer(r"Slot (s\d+): topic “([^”]*)”; archetype (\w+); difficulty (\d); format (\w+)", user):
        counter += 1
        qs.append({"importId": "m%d" % counter, "type": "single_choice", "title": "Generated %d" % counter, "difficulty": int(m.group(4)), "learningObjective": "Practice %s" % m.group(2),
                   "content": [{"kind": "markdown", "text": STEMS[counter % len(STEMS)].format(n=counter, t=m.group(2))}],
                   "answer": {"choices": [{"id": "a", "text": str(counter), "why": "This is the value the method gives."}, {"id": "b", "text": str(counter + 100), "why": "This ignores the conditioning event."}], "correctIds": ["a"]},
                   "evaluation": {"method": "choice"}, "hints": ["Condition first."], "solution": [{"kind": "markdown", "text": "Restrict the support, then divide."}], "skills": [m.group(2)],
                   "metadata": {"provenance": {"slotId": m.group(1), "topic": m.group(2), "reasoningSkills": ["Restrict joint support before conditioning"], "primaryArchetype": m.group(3), "origin": "generated_variant"}}})
    return json.dumps({"schemaVersion": "cramlab.questions.v2", "requestId": rid, "questions": qs})

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send({"object": "list", "data": [{"id": "scripted-model", "object": "model"}]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        text = "\n".join(str(m.get("content", "")) for m in body.get("messages", []))
        if "You analyze course material" in text: log("topics"); self._send(reply(json.dumps(TOPICS)))
        elif "req-" in text and "Slot s" in text: log("questions"); self._send(reply(questions(text)))
        elif "Summarize these course notes" in text: log("summary"); self._send(reply("## Overview\nMaximum likelihood picks the parameter that makes the data most likely.\n\n**Key:** \\(\\hat\\theta=\\arg\\max L(\\theta)\\)"))
        else: log("chat"); self._send(reply("Okay."))

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
