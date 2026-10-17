import { useDialogs } from "./components/dialogs";
import { Button, Input } from "./components/controls";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { acceptInvitation, createTeam, inviteMember, listMembers, listMyInvitations, listTeamInvitations, removeMember, revokeInvitation, updateMember, type Invitation, type Member, type Permissions, type Space, type User } from "./api";
import { message } from "./App";

type Props = { space: Space; permissions: Permissions; user: User; reloadSpaces: (preferred?: string) => Promise<void>; onError: (value: string) => void };

export function Teams({ space, permissions, user, reloadSpaces, onError }: Props) {
  const { confirm } = useDialogs();
  const [members, setMembers] = useState<Member[]>([]);
  const [pending, setPending] = useState<Invitation[]>([]);
  const [mine, setMine] = useState<Invitation[]>([]);
  const [busy, setBusy] = useState(false);
  const [inviteeId, setInviteeId] = useState("");
  const [role, setRole] = useState("viewer");

  const reload = useCallback(async () => {
    const results = await Promise.all([
      listMyInvitations(),
      space.kind === "team" ? listMembers(space.space_id) : Promise.resolve({ members: [] }),
      space.kind === "team" && permissions.can_manage_members ? listTeamInvitations(space.space_id) : Promise.resolve({ invitations: [] }),
    ]);
    setMine(results[0].invitations); setMembers(results[1].members); setPending(results[2].invitations);
  }, [space.space_id, space.kind, permissions.can_manage_members]);

  useEffect(() => { void reload().catch(problem => onError(message(problem))); }, [reload, onError]);

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true);
    const form = event.currentTarget;
    const name = String(new FormData(form).get("team_name") ?? "");
    try {
      const result = await createTeam(name);
      form.reset();
      await reloadSpaces(result.space.space_id);
    } catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function invite(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true);
    try { await inviteMember(space.space_id, inviteeId.trim(), role); setInviteeId(""); await reload(); }
    catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function accept(invitation: Invitation) {
    setBusy(true);
    try { await acceptInvitation(invitation.invitation_id); await reloadSpaces(invitation.space_id); await reload(); }
    catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function changeRole(member: Member, next: string) {
    setBusy(true);
    try { await updateMember(space.space_id, member.user_id, next); await reload(); }
    catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function remove(member: Member) {
    if (!(await confirm(`Remove member ${member.user_id}?`))) return;
    setBusy(true);
    try { await removeMember(space.space_id, member.user_id); await reload(); if (member.user_id === user.user_id) await reloadSpaces(); }
    catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  return <div className="content-wrap">
    <header className="section-header"><div><span className="eyebrow">TEAM & ACCESS</span><h2>{space.kind === "team" ? space.name : "Team management"}</h2><p>Team members can view shared content by default. Their role controls what they can change.</p></div></header>
    {mine.length > 0 && <section className="card"><h3>My team invitations</h3><div className="list-lines">{mine.map(item => <div className="list-line" key={item.invitation_id}><div><strong>Team {item.space_id}</strong><small>Role: {item.role} · Expires {new Date(item.expires_at).toLocaleDateString("en-US")}</small></div><Button className="secondary" disabled={busy} onClick={() => void accept(item)}>Accept invitation</Button></div>)}</div></section>}
    {space.kind === "personal" && <section className="card"><h3>Create a team</h3><form className="inline-form" onSubmit={event => void create(event)}><label>Team name<Input name="team_name" required maxLength={120} placeholder="For example, Research Team" /></label><Button className="primary" disabled={busy}>Create team</Button></form></section>}
    {space.kind === "team" && <>
      <section className="card"><div className="card-heading"><h3>Members</h3><span>{members.length}</span></div><div className="list-lines">{members.map(member => <div className="list-line" key={member.user_id}><div><code>{member.user_id}</code><small>{member.user_id === user.user_id ? "You" : "Member"}</small></div><div className="line-actions">{permissions.can_manage_members ? <><select aria-label={`Role for member ${member.user_id}`} value={member.role} disabled={busy || (member.role === "owner" && permissions.role !== "owner")} onChange={event => void changeRole(member, event.target.value)}>{["owner", "admin", "editor", "viewer"].filter(value => value !== "owner" || permissions.role === "owner").map(value => <option key={value} value={value}>{value}</option>)}</select><Button className="text-button danger" disabled={busy} onClick={() => void remove(member)}>Remove</Button></> : <span className="badge">{member.role}</span>}</div></div>)}</div></section>
      {permissions.can_manage_members && <section className="card"><h3>Invite a member</h3><p className="hint">Invitees must register with Vessel first and send you their user ID.</p><form className="inline-form" onSubmit={event => void invite(event)}><label>Invitee user ID<Input value={inviteeId} onChange={event => setInviteeId(event.target.value)} required placeholder="User ID" /></label><label>Invitation role<select value={role} onChange={event => setRole(event.target.value)}>{["viewer", "editor", "admin", ...(permissions.role === "owner" ? ["owner"] : [])].map(value => <option key={value} value={value}>{value}</option>)}</select></label><Button className="primary" disabled={busy}>Send invitation</Button></form>
        {pending.length > 0 && <><h4>Pending</h4><div className="list-lines">{pending.map(item => <div className="list-line" key={item.invitation_id}><div><code>{item.invitee_user_id}</code><small>{item.role} · Expires {new Date(item.expires_at).toLocaleDateString("en-US")}</small></div><Button className="text-button" disabled={busy} onClick={async () => { if (await confirm(`Revoke the invitation for ${item.invitee_user_id}?`)) void revokeInvitation(space.space_id, item.invitation_id).then(reload).catch(problem => onError(message(problem))); }}>Revoke</Button></div>)}</div></>}
      </section>}
    </>}
  </div>;
}
