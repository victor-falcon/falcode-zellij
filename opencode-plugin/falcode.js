/**
 * OpenCode plugin for Zellij session status reporting.
 *
 * Install this file into ~/.config/opencode/plugins/falcode.js and add it to
 * ~/.config/opencode/config.json under the `plugin` array.
 */

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

/** @param {import("@opencode-ai/plugin").PluginInput} _input */
export default async (_input) => {
  const paneId = Bun.env.ZELLIJ_PANE_ID;
  const sessionName = Bun.env.ZELLIJ_SESSION_NAME;
  if (!paneId || !sessionName) {
    return {};
  }

  const stateRoot =
    Bun.env.FALCODE_STATE_DIR ??
    path.join(Bun.env.HOME ?? ".", ".local", "state", "falcode-zellij");
  const panesDir = path.join(stateRoot, "panes");
  const stateFile = path.join(panesDir, `${paneId}.json`);
  mkdirSync(panesDir, { recursive: true });

  const cwd = Bun.env.PWD ?? process.cwd();

  function writeState(status) {
    const payload = {
      agent: "opencode",
      cwd,
      pane_id: Number.parseInt(paneId, 10),
      session_name: sessionName,
      status,
      updated_at_ms: Date.now(),
    };
    writeFileSync(stateFile, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  }

  function handleEvent(evt) {
    switch (evt.type) {
      case "permission":
        writeState("asking_permissions");
        break;
      case "question":
        writeState("waiting_user_answers");
        break;
      case "idle":
        writeState("waiting_user_input");
        break;
      case "status": {
        const status = evt.status;
        if (status === "busy" || status === "running") {
          writeState("working");
        } else if (status === "idle") {
          writeState("waiting_user_input");
        }
        break;
      }
    }
  }

  try {
    const existing = JSON.parse(readFileSync(stateFile, "utf8"));
    writeState(existing?.status ?? "waiting_user_input");
  } catch {
    writeState("waiting_user_input");
  }

  process.on("exit", () => {
    rmSync(stateFile, { force: true });
  });

  return {
    async "permission.ask"() {
      handleEvent({ type: "permission" });
    },

    async "tool.execute.before"(input) {
      if (input.tool === "question") {
        handleEvent({ type: "question" });
      }
    },

    async event({ event }) {
      switch (event.type) {
        case "session.status":
          handleEvent({
            type: "status",
            status: event.properties?.status?.type ?? "idle",
          });
          break;
        case "session.idle":
          handleEvent({ type: "idle" });
          break;
        case "permission.replied":
          handleEvent({ type: "status", status: "busy" });
          break;
      }
    },
  };
};
