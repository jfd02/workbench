-- Subscribe to agent.finished or agent.blocked. Values stay data, not code.
set agentName to system attribute "WORKBENCH_AGENT"
if agentName is "" then set agentName to "Agent"
set workspaceName to system attribute "WORKBENCH_BRANCH"
if workspaceName is "" then set workspaceName to "Home"
if (system attribute "WORKBENCH_EVENT") is "agent.blocked" then
    set detail to agentName & " needs your input in " & workspaceName
else
    set detail to agentName & " finished in " & workspaceName
end if
display notification detail with title "Workbench"
