// Vedetta Terminal Focus — bridges Vedetta to the integrated terminal that
// hosts an agent session. Two URIs, both carrying the session's process
// ancestry (pid=A&pid=B&…, captured at hook time — includes the terminal's
// shell, matched against terminal.processId) plus its workspace path so a
// wrong window stays silent:
//   /focus            reveals the terminal tab
//   /answer?keys=…    writes keys straight into the terminal's stdin
//                     (terminal.sendText) to drive a native picker — real
//                     injection, no synthesized global keystrokes, no focus.
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

// Runs `action(terminal)` on the integrated terminal whose shell is in the
// pid set (direct hit), falling back to an ancestor walk (older builds sent
// a single pid whose shell is an ancestor).
async function withTerminal(pids, action) {
	const wanted = new Set(pids);
	for (const terminal of vscode.window.terminals) {
		const shellPid = await terminal.processId;
		if (shellPid && wanted.has(shellPid)) {
			action(terminal);
			return;
		}
	}
	processParents(async (parents) => {
		const chain = new Set();
		for (const pid of pids) {
			for (const ancestor of ancestorsOf(pid, parents)) chain.add(ancestor);
		}
		for (const terminal of vscode.window.terminals) {
			const shellPid = await terminal.processId;
			if (shellPid && chain.has(shellPid)) {
				action(terminal);
				return;
			}
		}
	});
}

// The URI lands in ONE window (the focused one); this extension instance
// only sees its own window's terminals. Vedetta sends the session's
// workspace path so an instance whose workspace doesn't match stays silent.
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
				const params = new URLSearchParams(uri.query);
				if (!ownsWorkspace(params.get("workspace"))) return;
				const pids = params
					.getAll("pid")
					.map((value) => Number(value))
					.filter((pid) => Number.isInteger(pid) && pid > 0);
				if (pids.length === 0) return;

				if (uri.path === "/focus") {
					withTerminal(pids, (terminal) => terminal.show(false));
				} else if (uri.path === "/answer") {
					// URLSearchParams already percent-decodes; the keys string
					// carries raw control bytes (arrows, CR, …) for the picker.
					const keys = params.get("keys");
					if (keys) withTerminal(pids, (terminal) => terminal.sendText(keys, false));
				}
			},
		})
	);
}

function deactivate() {}

module.exports = { activate, deactivate };
