import { useCallback, useEffect, useState, type FormEvent } from "react";
import { acceptInvitation, createTeam, inviteMember, listMembers, listMyInvitations, listTeamInvitations, removeMember, revokeInvitation, updateMember, type Invitation, type Member, type Permissions, type Space, type User } from "./api";
import { message } from "./App";

type Props = { space: Space; permissions: Permissions; user: User; reloadSpaces: (preferred?: string) => Promise<void>; onError: (value: string) => void };

export function Teams({ space, permissions, user, reloadSpaces, onError }: Props) {
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
    if (!window.confirm(`移除成员 ${member.user_id}？`)) return;
    setBusy(true);
    try { await removeMember(space.space_id, member.user_id); await reload(); if (member.user_id === user.user_id) await reloadSpaces(); }
    catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  return <div className="content-wrap">
    <header className="section-header"><div><span className="eyebrow">TEAM & ACCESS</span><h2>{space.kind === "team" ? space.name : "团队管理"}</h2><p>团队成员默认能查看空间内容，读写由角色决定。</p></div></header>
    {mine.length > 0 && <section className="card"><h3>邀请我的团队</h3><div className="list-lines">{mine.map(item => <div className="list-line" key={item.invitation_id}><div><strong>团队 {item.space_id}</strong><small>角色：{item.role} · 截止 {new Date(item.expires_at).toLocaleDateString()}</small></div><button className="secondary" disabled={busy} onClick={() => void accept(item)}>接受邀请</button></div>)}</div></section>}
    {space.kind === "personal" && <section className="card"><h3>创建团队</h3><form className="inline-form" onSubmit={event => void create(event)}><label>团队名称<input name="team_name" required maxLength={120} placeholder="例如：Research Team" /></label><button className="primary" disabled={busy}>创建团队</button></form></section>}
    {space.kind === "team" && <>
      <section className="card"><div className="card-heading"><h3>成员</h3><span>{members.length} 人</span></div><div className="list-lines">{members.map(member => <div className="list-line" key={member.user_id}><div><code>{member.user_id}</code><small>{member.user_id === user.user_id ? "我" : "成员"}</small></div><div className="line-actions">{permissions.can_manage_members ? <><select aria-label={`成员 ${member.user_id} 的角色`} value={member.role} disabled={busy || (member.role === "owner" && permissions.role !== "owner")} onChange={event => void changeRole(member, event.target.value)}>{["owner", "admin", "editor", "viewer"].filter(value => value !== "owner" || permissions.role === "owner").map(value => <option key={value} value={value}>{value}</option>)}</select><button className="text-button danger" disabled={busy} onClick={() => void remove(member)}>移除</button></> : <span className="badge">{member.role}</span>}</div></div>)}</div></section>
      {permissions.can_manage_members && <section className="card"><h3>邀请成员</h3><p className="hint">被邀请人先注册 Vessel，并把个人资料中的用户 ID 发给你。</p><form className="inline-form" onSubmit={event => void invite(event)}><label>受邀用户 ID<input value={inviteeId} onChange={event => setInviteeId(event.target.value)} required placeholder="用户 ID" /></label><label>邀请角色<select value={role} onChange={event => setRole(event.target.value)}>{["viewer", "editor", "admin", ...(permissions.role === "owner" ? ["owner"] : [])].map(value => <option key={value} value={value}>{value}</option>)}</select></label><button className="primary" disabled={busy}>发送邀请</button></form>
        {pending.length > 0 && <><h4>待接受</h4><div className="list-lines">{pending.map(item => <div className="list-line" key={item.invitation_id}><div><code>{item.invitee_user_id}</code><small>{item.role} · {new Date(item.expires_at).toLocaleDateString()} 到期</small></div><button className="text-button" disabled={busy} onClick={() => { if (window.confirm(`撤销发给 ${item.invitee_user_id} 的邀请？`)) void revokeInvitation(space.space_id, item.invitation_id).then(reload).catch(problem => onError(message(problem))); }}>撤销</button></div>)}</div></>}
      </section>}
    </>}
  </div>;
}
