// Vedetta Terminal Focus — focuses the integrated terminal that hosts an
// agent session. Vedetta opens vscode://vedetta.terminal-focus/focus?pid=N
// where N is a pid inside the session's process tree; the terminal whose
// shell is an ancestor of that pid is revealed.
const vscode = require("vscode");
const { execFile } = require("child_process");

function processParents(callback) {
	execFile("ps", ["-Ao", "pid=,ppid="], { maxBuffer: 4 << 20 }, (error, stdout) => {
		const parents = new Map();
		if (!error) {
			for (const line of stdout.split("\n")) {
				const match = line.trim().match(/^(\d+)\s+(\d+)$/);
				if (match) parents.set(Number(match[1]), Number(match[2]));
			}
		}
		callback(parents);
	});
}

function ancestorsOf(pid, parents) {
	const chain = new Set();
	let current = pid;
	for (let i = 0; i < 30 && current && current > 1; i++) {
		chain.add(current);
		current = parents.get(current);
	}
	return chain;
}

async function focusTerminalFor(pid) {
	processParents(async (parents) => {
		const chain = ancestorsOf(pid, parents);
		for (const terminal of vscode.window.terminals) {
			const shellPid = await terminal.processId;
			if (shellPid && chain.has(shellPid)) {
				terminal.show(false);
				return;
			}
		}
	});
}

// The URI lands in ONE window (the focused one); this extension instance
// only sees its own window's terminals. Vedetta raises the session's
// window first and sends its workspace path along — an instance whose
// workspace doesn't match stays silent instead of doing nothing useful.
function ownsWorkspace(dir) {
	const trim = (value) => String(value || "").replace(/\/+$/, "");
	const target = trim(dir);
	if (!target) return true;
	const folders = vscode.workspace.workspaceFolders || [];
	return folders.some((folder) => {
		const base = trim(folder.uri.fsPath);
		return base === target || target.startsWith(base + "/");
	});
}

function activate(context) {
	context.subscriptions.push(
		vscode.window.registerUriHandler({
			handleUri(uri) {
				if (uri.path !== "/focus") return;
				const params = new URLSearchParams(uri.query);
				if (!ownsWorkspace(params.get("workspace"))) return;
				const pid = Number(params.get("pid"));
				if (pid) focusTerminalFor(pid);
			},
		})
	);
}

function deactivate() {}

module.exports = { activate, deactivate };
