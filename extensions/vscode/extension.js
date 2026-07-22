// Vedetta Terminal Focus — bridges Vedetta to the integrated terminal that
// hosts an agent session. Claude answers never come through here (they ride
// the hook as data); Codex TUI questions have no hook channel, so their
// answer is typed into the EXACT terminal via the API — never a global
// keystroke.
//
// URIs carry the session's process ancestry (pid=A&pid=B&…, captured at hook
// time — the terminal's live shell is matched against terminal.processId)
// plus its workspace path so a wrong window stays silent:
//   /focus    reveals the terminal tab (Vedetta raises the window first).
//
// Answers travel over a FILE channel instead (~/.vedetta/run/commands/*.json):
// every window's instance watches it and only the one owning the terminal
// types — no URI, no window raise, the user's focus stays untouched.
const vscode = require("vscode");
const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");

function log(message) {
	try {
		fs.appendFileSync(
			os.homedir() + "/.vedetta/run/ext.log",
			new Date().toISOString() + " " + message + "\n"
		);
	} catch (e) {}
}

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

// The URI lands in ONE window (the focused one); this extension instance only
// sees its own window's terminals. Vedetta sends the session's workspace path
// so an instance whose workspace doesn't contain it stays silent.
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

const COMMANDS_DIR = os.homedir() + "/.vedetta/run/commands";

// Consumes one command file: {action:"answer", pids:[…], text:"…", at:epoch}.
// Every window's instance sees the file; only the one owning the terminal
// types, then deletes the file (unlink races are harmless no-ops).
function consumeCommandFile(name) {
	if (!name || !name.endsWith(".json")) return;
	const path = COMMANDS_DIR + "/" + name;
	let command;
	try {
		command = JSON.parse(fs.readFileSync(path, "utf8"));
	} catch (e) {
		return; // partial write or already consumed
	}
	if (command.action !== "answer" || !command.text) return;
	if (Math.abs(Date.now() / 1000 - (command.at || 0)) > 15) {
		try { fs.unlinkSync(path); } catch (e) {}
		return; // stale leftover
	}
	const pids = (command.pids || []).filter((pid) => Number.isInteger(pid) && pid > 0);
	if (pids.length === 0) return;
	withTerminal(pids, (terminal) => {
		terminal.sendText(command.text, false);
		try { fs.unlinkSync(path); } catch (e) {}
		log(`answer typed silently (${command.text.length} chars)`);
	});
}

function activate(context) {
	try {
		fs.mkdirSync(COMMANDS_DIR, { recursive: true });
		const watcher = fs.watch(COMMANDS_DIR, (event, name) => consumeCommandFile(name));
		context.subscriptions.push({ dispose: () => watcher.close() });
		// Catch anything written while this window was reloading.
		for (const name of fs.readdirSync(COMMANDS_DIR)) consumeCommandFile(name);
	} catch (e) {
		log("command watcher failed: " + e);
	}
	context.subscriptions.push(
		vscode.window.registerUriHandler({
			handleUri(uri) {
				const params = new URLSearchParams(uri.query);
				const owns = ownsWorkspace(params.get("workspace"));
				log(`uri path=${uri.path} owns=${owns} ws=${params.get("workspace")}`);
				if (!owns) return;
				const pids = params
					.getAll("pid")
					.map((value) => Number(value))
					.filter((pid) => Number.isInteger(pid) && pid > 0);
				if (pids.length === 0) return;
				if (uri.path === "/focus") withTerminal(pids, (terminal) => terminal.show(false));
			},
		})
	);
}

function deactivate() {}

module.exports = { activate, deactivate };
