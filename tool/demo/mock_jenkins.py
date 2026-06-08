#!/usr/bin/env python3
"""演示用 Jenkins Mock 服务器（仅供 README 截图，绝不连真实 Jenkins）。

返回一组虚构的「演示数据」：项目树、参数化 Job、一个正处于「进行中」的构建
（部分阶段已绿、一个阶段运行中、其余待执行）以及一段实时控制台日志。

为了让截图与抓取时机无关，构建状态是**确定性的**（永远停在同一个中间进度），
不随时间推进。

无第三方依赖，Python3 标准库即可：
    python3 tool/demo/mock_jenkins.py 8732
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8732
HOST = "127.0.0.1"
BASE = f"http://{HOST}:{PORT}"

# 进行中的构建号 / 上一条已完成构建号
RUNNING = 128
PREV = 127

# ---- 演示项目树 ----------------------------------------------------------
TREE = {
    "jobs": [
        {
            "_class": "com.cloudbees.hudson.plugins.folder.Folder",
            "name": "backend",
            "url": f"{BASE}/job/backend/",
            "color": None,
            "jobs": [
                {
                    "_class": "hudson.model.FreeStyleProject",
                    "name": "order-service",
                    "url": f"{BASE}/job/backend/job/order-service/",
                    "color": "blue",
                    "buildable": True,
                },
                {
                    "_class": "hudson.model.FreeStyleProject",
                    "name": "payment-service",
                    "url": f"{BASE}/job/backend/job/payment-service/",
                    "color": "blue",
                    "buildable": True,
                },
                {
                    "_class": "hudson.model.FreeStyleProject",
                    "name": "inventory-service",
                    "url": f"{BASE}/job/backend/job/inventory-service/",
                    "color": "yellow",
                    "buildable": True,
                },
            ],
        },
        {
            "_class": "com.cloudbees.hudson.plugins.folder.Folder",
            "name": "frontend",
            "url": f"{BASE}/job/frontend/",
            "color": None,
            "jobs": [
                {
                    "_class": "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject",
                    "name": "web-portal",
                    "url": f"{BASE}/job/frontend/job/web-portal/",
                    "color": None,
                    "jobs": [
                        {
                            "_class": "org.jenkinsci.plugins.workflow.job.WorkflowJob",
                            "name": "main",
                            "url": f"{BASE}/job/frontend/job/web-portal/job/main/",
                            "color": "blue",
                            "buildable": True,
                        },
                        {
                            "_class": "org.jenkinsci.plugins.workflow.job.WorkflowJob",
                            "name": "develop",
                            "url": f"{BASE}/job/frontend/job/web-portal/job/develop/",
                            "color": "blue",
                            "buildable": True,
                        },
                    ],
                },
                {
                    "_class": "hudson.model.FreeStyleProject",
                    "name": "admin-dashboard",
                    "url": f"{BASE}/job/frontend/job/admin-dashboard/",
                    "color": "red",
                    "buildable": True,
                },
            ],
        },
        {
            "_class": "hudson.model.FreeStyleProject",
            "name": "infra-deploy",
            "url": f"{BASE}/job/infra-deploy/",
            "color": "blue",
            "buildable": True,
        },
    ]
}

# ---- 参数定义 ------------------------------------------------------------
PARAM_DEFS = [
    {
        "_class": "net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition",
        "name": "BRANCH",
        "type": "PT_BRANCH_TAG",
        "description": "选择要发版的分支或 Tag",
        "defaultParameterValue": {"value": "origin/release/1.4.0"},
    },
    {
        "_class": "hudson.model.ChoiceParameterDefinition",
        "name": "ENV",
        "type": "ChoiceParameterDefinition",
        "description": "目标环境",
        "defaultParameterValue": {"value": "staging"},
        "choices": ["dev", "staging", "prod"],
    },
    {
        "_class": "hudson.model.StringParameterDefinition",
        "name": "VERSION",
        "type": "StringParameterDefinition",
        "description": "发布版本号",
        "defaultParameterValue": {"value": "1.4.0"},
    },
    {
        "_class": "hudson.model.BooleanParameterDefinition",
        "name": "SKIP_TESTS",
        "type": "BooleanParameterDefinition",
        "description": "跳过单元测试",
        "defaultParameterValue": {"value": False},
    },
    {
        "_class": "hudson.model.TextParameterDefinition",
        "name": "RELEASE_NOTE",
        "type": "TextParameterDefinition",
        "description": "发布说明（可选）",
        "defaultParameterValue": {"value": ""},
    },
]

GIT_BRANCHES = [
    "origin/main",
    "origin/release/1.4.0",
    "origin/release/1.3.2",
    "origin/develop",
    "origin/feature/coupon-engine",
    "refs/tags/v1.3.1",
    "refs/tags/v1.3.0",
]

LOG_LINES = [
    "Started by user 演示用户 (demo)",
    "Running as SYSTEM",
    "Building remotely on demo-agent-02 (linux docker) in workspace /home/jenkins/workspace/order-service",
    "[Pipeline] Start of Pipeline",
    "[Pipeline] node",
    "[order-service] $ git checkout origin/release/1.4.0",
    "Checking out Revision a1b2c3d4e5f6a7b8 (origin/release/1.4.0)",
    " > git rev-parse --resolve-git-dir HEAD # timeout=10",
    "[INFO] ------------------------------------------------------------------",
    "[INFO] Building order-service 1.4.0",
    "[INFO] ------------------------------------------------------------------",
    "[INFO] Resolving dependencies (pnpm)...",
    "npm WARN deprecated lodash.isequal@4.5.0: This package is deprecated. Use require('node:util').isDeepStrictEqual instead.",
    "[INFO] Dependencies resolved in 8.2s",
    "[INFO] Compiling TypeScript sources (214 files)...",
    "[INFO] Compilation finished, 0 errors",
    "[INFO] Running unit tests (42 specs)...",
    "[INFO]   ✓ auth.controller.spec.ts (12 passed)",
    "[INFO]   ✓ order.service.spec.ts (18 passed)",
    "[INFO]   ✓ payment.gateway.spec.ts (8 passed)",
    "[INFO]   ▶ inventory.sync.spec.ts (running 4 / 4)...",
]
LOG_TEXT = "\n".join(LOG_LINES) + "\n"

# ---- 阶段（进行中：2 段成功 / 1 段运行中 / 2 段待执行）-------------------
STAGES_RUNNING = [
    {"id": "6", "name": "Checkout", "status": "SUCCESS", "durationMillis": 4200, "startTimeMillis": 0},
    {"id": "12", "name": "Build", "status": "SUCCESS", "durationMillis": 12300, "startTimeMillis": 4200},
    {"id": "20", "name": "Unit Test", "status": "IN_PROGRESS", "durationMillis": 7600, "startTimeMillis": 16500},
    {"id": "28", "name": "Package", "status": "NOT_EXECUTED", "durationMillis": 0},
    {"id": "34", "name": "Deploy", "status": "NOT_EXECUTED", "durationMillis": 0},
]
STAGES_PREV = [
    {"id": "6", "name": "Checkout", "status": "SUCCESS", "durationMillis": 4100, "startTimeMillis": 0},
    {"id": "12", "name": "Build", "status": "SUCCESS", "durationMillis": 11800, "startTimeMillis": 4100},
    {"id": "20", "name": "Unit Test", "status": "SUCCESS", "durationMillis": 9000, "startTimeMillis": 15900},
    {"id": "28", "name": "Package", "status": "SUCCESS", "durationMillis": 5200, "startTimeMillis": 24900},
    {"id": "34", "name": "Deploy", "status": "SUCCESS", "durationMillis": 7400, "startTimeMillis": 30100},
]


def now_ms():
    return int(time.time() * 1000)


def history_builds(count):
    """已完成的历史构建（不含进行中的 RUNNING，避免占用本次 trigger 的构建号）。"""
    out = []
    base = now_ms() - 3600_000
    results = ["SUCCESS", "SUCCESS", "FAILURE", "SUCCESS", "SUCCESS", "SUCCESS"]
    for i in range(count):
        n = PREV - i
        if n <= 0:
            break
        out.append({
            "number": n,
            "url": f"{BASE}/job/backend/job/order-service/{n}/",
            "result": results[i % len(results)],
            "building": False,
            "timestamp": base - i * 600_000,
            "duration": 41000 + (i * 1300),
            "estimatedDuration": 42000,
            "displayName": f"#{n}",
            "fullDisplayName": f"order-service #{n}",
            "actions": [
                {"parameters": [
                    {"name": "BRANCH", "value": "origin/release/1.3.2" if i else "origin/release/1.4.0"},
                    {"name": "ENV", "value": "prod" if i % 2 else "staging"},
                    {"name": "VERSION", "value": f"1.3.{2 - (i % 3)}"},
                ]},
                {"causes": [{"_class": "hudson.model.Cause$UserIdCause", "userId": "demo", "userName": "演示用户"}]},
                {"lastBuiltRevision": {"SHA1": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"}},
            ],
        })
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # 静默

    def _send_json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Jenkins", "2.426.3")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text, status=200, extra_headers=None):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    # ---- GET ----
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        # 根 /api/json
        if path == "/api/json":
            tree = qs.get("tree", [""])[0]
            if "jobs" in tree or "views" in tree:
                self._send_json(TREE)
            else:
                self._send_json({"mode": "NORMAL", "nodeName": "", "useSecurity": True})
            return

        if path == "/crumbIssuer/api/json":
            self._send_json({"crumbRequestField": "Jenkins-Crumb", "crumb": "demo0crumb0token"})
            return

        # fillValueItems（git parameter 分支候选）
        if path.endswith("/fillValueItems"):
            self._send_json({"values": [{"value": b, "name": b} for b in GIT_BRANCHES]})
            return

        # wfapi/describe（阶段）
        if path.endswith("/wfapi/describe"):
            n = self._build_number_in(path)
            stages = STAGES_RUNNING if n == RUNNING else STAGES_PREV
            self._send_json({
                "name": f"#{n}",
                "status": "IN_PROGRESS" if n == RUNNING else "SUCCESS",
                "stages": stages,
            })
            return

        # progressiveText（控制台日志）
        if path.endswith("/logText/progressiveText"):
            start = int(qs.get("start", ["0"])[0])
            total = len(LOG_TEXT.encode("utf-8"))
            if start >= total:
                self._send_text("", extra_headers={"X-Text-Size": str(total), "X-More-Data": "true"})
            else:
                self._send_text(LOG_TEXT, extra_headers={"X-Text-Size": str(total), "X-More-Data": "true"})
            return

        # 队列项
        if path.startswith("/queue/item/"):
            self._send_json({
                "id": 4242,
                "cancelled": False,
                "executable": {"number": RUNNING, "url": f"{BASE}/job/backend/job/order-service/{RUNNING}/"},
            })
            return

        # /job/.../{n}/api/json  —— 构建详情
        n = self._build_number_in(path)
        if path.endswith("/api/json") and n is not None:
            self._send_json({
                "number": n,
                "url": f"{BASE}/job/backend/job/order-service/{n}/",
                "building": n == RUNNING,
                "result": None if n == RUNNING else "SUCCESS",
                "timestamp": now_ms() - 18000,
                "duration": 0 if n == RUNNING else 41000,
                "estimatedDuration": 42000,
                "displayName": f"#{n}",
                "fullDisplayName": f"order-service #{n}",
            })
            return

        # /job/.../api/json  —— Job 详情 / 历史
        if path.endswith("/api/json"):
            tree = qs.get("tree", [""])[0]
            if "builds" in tree:
                self._send_json({"builds": history_builds(20)})
                return
            # Job 详情（含参数定义）
            self._send_json({
                "_class": "hudson.model.FreeStyleProject",
                "name": "order-service",
                "fullName": "backend/order-service",
                "url": f"{BASE}/job/backend/job/order-service/",
                "buildable": True,
                "description": "订单服务 · 发版流水线（演示数据）",
                "lastBuild": {"number": RUNNING},
                "lastCompletedBuild": {"number": PREV, "result": "SUCCESS"},
                "property": [
                    {
                        "_class": "hudson.model.ParametersDefinitionProperty",
                        "parameterDefinitions": PARAM_DEFS,
                    }
                ],
                "actions": [{"parameterDefinitions": PARAM_DEFS}],
                "builds": history_builds(20),
            })
            return

        self._send_json({"error": "not found"}, status=404)

    # ---- POST ----
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        # 读掉请求体
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(length)

        if path.endswith("/buildWithParameters") or path.endswith("/build"):
            loc = f"{BASE}/queue/item/4242/"
            self.send_response(201)
            self.send_header("Location", loc)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path.endswith("/stop") or path.endswith("/term") or path.endswith("/kill"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    @staticmethod
    def _build_number_in(path):
        """从 /job/.../{n}/(api/json|wfapi/...) 中取构建号，没有则 None。"""
        parts = [p for p in path.split("/") if p]
        for i, p in enumerate(parts):
            if p.isdigit():
                return int(p)
        return None


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"mock-jenkins listening on {BASE}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
