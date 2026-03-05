import React from "react";

function parseBranchConclusion(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const summary = typeof payload.summary === "string" ? payload.summary.trim() : "";
  const tokenUsage =
    payload.tokenUsage && typeof payload.tokenUsage === "object" ? payload.tokenUsage : null;
  const prompt = tokenUsage && typeof tokenUsage.prompt === "number" ? tokenUsage.prompt : null;
  const completion =
    tokenUsage && typeof tokenUsage.completion === "number" ? tokenUsage.completion : null;

  const artifactRefs = Array.isArray(payload.artifactRefs)
    ? payload.artifactRefs.filter((ref) => ref && typeof ref === "object")
    : [];
  const memoryRefs = Array.isArray(payload.memoryRefs)
    ? payload.memoryRefs.filter((ref) => ref && typeof ref === "object")
    : [];

  return {
    summary,
    prompt,
    completion,
    artifactRefs,
    memoryRefs
  };
}

export function RuntimeOverviewView({
  title,
  text,
  onTextChange,
  onSend,
  messages,
  tasks,
  artifactId,
  onArtifactIdChange,
  onLoadArtifact,
  artifactContent,
  events
}) {
  return (
    <main className="grid">
      <section className="panel">
        <h2>{title === "Chats" ? "Chat" : "Chat Stream"}</h2>
        <form onSubmit={onSend} className="chat-form">
          <textarea value={text} onChange={(event) => onTextChange(event.target.value)} rows={3} />
          <button type="submit">Send</button>
        </form>
        <div className="log">
          {messages.map((message) => (
            <article key={message.id} className="log-item">
              <strong>{message.userId}</strong>
              <p>{message.content}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="panel">
        <h2>Tasks</h2>
        {tasks.map((task) => (
          <article key={task.id} className="task-card">
            <h3>{task.title}</h3>
            <p>Status: {task.status}</p>
            <p>Reason: {task.reason}</p>
          </article>
        ))}
      </section>

      <section className="panel">
        <h2>Artifacts</h2>
        <div className="artifact-controls">
          <input
            value={artifactId}
            onChange={(event) => onArtifactIdChange(event.target.value)}
            placeholder="artifact id"
          />
          <button type="button" onClick={onLoadArtifact}>
            Load
          </button>
        </div>
        <pre>{artifactContent}</pre>
      </section>

      <section className="panel">
        <h2>Activity Feed</h2>
        <div className="feed">
          {events.map((event) => {
            const swarm = event.extensions && typeof event.extensions === "object" ? event.extensions.swarm : null;
            const swarmRef = swarm && typeof swarm === "object" && typeof swarm.swarmId === "string"
              ? `swarm:${swarm.swarmId}`
              : null;
            const refs = [
              swarmRef,
              event.taskId ? `task:${event.taskId}` : null,
              event.branchId ? `branch:${event.branchId}` : null,
              event.workerId ? `worker:${event.workerId}` : null
            ]
              .filter(Boolean)
              .join(" • ");

            return (
              <article key={`${event.id}:${event.ts}`} className="feed-item">
                <strong>{event.messageType}</strong>
                <p>{new Date(event.ts).toLocaleString()}</p>
                {refs ? <p>{refs}</p> : null}
                {event.messageType === "branch.conclusion" ? (
                  (() => {
                    const conclusion = parseBranchConclusion(event.payload);
                    if (!conclusion) {
                      return null;
                    }

                    const artifactRefIds = conclusion.artifactRefs
                      .map((ref) => (typeof ref.id === "string" ? ref.id : null))
                      .filter(Boolean);
                    const memoryRefIds = conclusion.memoryRefs
                      .map((ref) => (typeof ref.id === "string" ? ref.id : null))
                      .filter(Boolean);

                    return (
                      <>
                        {conclusion.summary ? <p>Summary: {conclusion.summary}</p> : null}
                        {artifactRefIds.length > 0 ? <p>Artifacts: {artifactRefIds.join(", ")}</p> : null}
                        {memoryRefIds.length > 0 ? <p>Memory refs: {memoryRefIds.join(", ")}</p> : null}
                        {conclusion.prompt !== null && conclusion.completion !== null ? (
                          <p>
                            Token usage: prompt {conclusion.prompt}, completion {conclusion.completion}, total{" "}
                            {conclusion.prompt + conclusion.completion}
                          </p>
                        ) : null}
                      </>
                    );
                  })()
                ) : null}
              </article>
            );
          })}
          {events.length === 0 ? <p>No runtime events yet.</p> : null}
        </div>
      </section>
    </main>
  );
}
