import json
import pytest
from pydantic import SecretStr
from vessel_service.proposals.service import ProposalError


def test_auto_parser_accepts_typed_answer_and_rejects_unsafe_sources():
    from vessel_service.notes.agent_response import parse_agent_response
    value = {"schema_version": 1, "type": "answer", "message": "Hello"}
    assert parse_agent_response(json.dumps(value), base_revision=1) == value
    value["sources"] = [{"title": "bad", "url": "javascript:alert(1)"}]
    with pytest.raises(ProposalError):
        parse_agent_response(json.dumps(value), base_revision=1)


def test_auto_answer_and_clarification_continue_once(api_factory, monkeypatch):
    def configure(app):
        settings = app.state.settings
        settings.agent_platform_url = "https://agent.test"
        settings.agent_id = "test"
        settings.agent_gateway_user_id = "test"
        settings.agent_gateway_secret = SecretStr("test")
    api = api_factory(configure_application=configure)
    auth = api("POST", "/v1/auth/register", json={"name":"Test", "email":"auto@example.test", "password":"test-password-123"})
    headers = {"Authorization": f"Bearer {auth.json()['access_token']}"}
    note = api("POST", "/v1/notes", headers=headers, json={"title":"Draft", "document":{"type":"doc", "schema_version":1,"content":[]}}).json()["note"]
    path = f"/v1/notes/{note['note_id']}/agent"
    captured = []
    class Response:
        def __init__(self, payload): self.payload = payload
        def raise_for_status(self): pass
        def json(self): return self.payload
    def post(url, *, json, **kwargs):
        captured.append(json)
        return Response({"run_id":json["options"]["run_id"], "thread_id":json["thread_id"],"status":"queued"})
    output = {"schema_version":1,"type":"clarification","message":"Which tone?","options":[{"id":"short","label":"Short"}]}
    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", post)
    monkeypatch.setattr("vessel_service.agent_platform.httpx.get", lambda url, **kw: Response({"run_id":captured[-1]["options"]["run_id"],"status":"completed","output_text":json.dumps(output)}))
    start = api("POST",path+"/runs",headers=headers,json={"message":"Improve this"})
    assert start.status_code == 202, start.text
    run_id = start.json()["run_id"]
    result = api("GET",path+f"/runs/{run_id}",headers=headers).json()
    assert result["mode"] == "auto"
    assert result["response"] == output
    assert result["prompt"] == "Improve this"
    assert captured[0]["options"]["use_output_schema"] is False
    context = captured[0]["options"]["context"]["turn_prompt_context"]
    assert "EXACT_OPERATION_EXAMPLES" in context
    assert 'tableRow' in context
    assert 'tableCell' in context
    assert 'replace_range changes text; replace_block replaces an entire block' in context
    assert api("GET",path+"/status",headers=headers).json()["latest_run"]["run_id"] == run_id
    follow = {"message":"Short", "reply_to_run_id":run_id,"option_id":"short"}
    assert api("POST",path+"/runs",headers=headers,json=follow).status_code == 202
    assert "Improve this" in captured[-1]["options"]["context"]["turn_prompt_context"]
    child = captured[-1]["options"]["run_id"]
    assert api("GET",path+f"/runs/{run_id}",headers=headers).json()["answered_by_run_id"] == child
    output = {"schema_version":1,"type":"answer","message":"Done"}
    second = captured[-1]["options"]["run_id"]
    child_result = api("GET",path+f"/runs/{second}",headers=headers).json()
    assert child_result["response"] == output
    assert child_result["option_id"] == "short"
    repeated = api("POST",path+"/runs",headers=headers,json=follow)
    assert repeated.status_code == 409
    output = {"schema_version":1,"type":"edit","message":"Updated", "proposal":{"base_revision":note["revision"],"operations":[{"type":"set_title","title":"Better"}],"summary":"Title updated"}}
    edit = api("POST",path+"/runs",headers=headers,json={"message":"Change title"}).json()["run_id"]
    assert api("GET",path+f"/runs/{edit}",headers=headers).json()["response"] == output
    proposals = api("GET",f"/v1/notes/{note['note_id']}/proposals",headers=headers).json()["proposals"]
    assert proposals[0]["preview"]["title"] == "Better"
    assert api("GET",f"/v1/notes/{note['note_id']}",headers=headers).json()["note"]["title"] == "Draft"
    refined = api("POST",path+"/runs",headers=headers,json={"message":"Make it concise"})
    assert refined.status_code == 202
    assert "Better" in captured[-1]["options"]["context"]["turn_prompt_context"]
    output["proposal"]["operations"][0]["title"] = "Brief"
    assert api("GET",path+f"/runs/{refined.json()['run_id']}",headers=headers).json()["response"] == output
    proposals = api("GET",f"/v1/notes/{note['note_id']}/proposals",headers=headers).json()["proposals"]
    assert [p["status"] for p in proposals].count("ready") == 1
    # Permission is checked again on completion, even if it changed during the run.
    from fastapi import HTTPException
    import vessel_service.agent_platform as adapter
    access = adapter.note_for_user
    def read_only(session, user, note_id, *, write=False):
        if write:
            raise HTTPException(status_code=403, detail={"code":"SPACE_PERMISSION_DENIED"})
        return access(session, user, note_id)
    monkeypatch.setattr(adapter, "note_for_user", read_only)
    blocked = api("POST",path+"/runs",headers=headers,json={"message":"Change title again"}).json()["run_id"]
    blocked_result = api("GET",path+f"/runs/{blocked}",headers=headers).json()
    assert blocked_result["status"] == "failed"
    assert blocked_result["failure_code"] == "NOTE_AGENT_EDIT_FORBIDDEN"
    assert blocked_result["response"] is None
    assert len(api("GET",f"/v1/notes/{note['note_id']}/proposals",headers=headers).json()["proposals"]) == 1
    output = {"schema_version":1,"type":"answer","message":"Safe"}
    ask = api("POST",path+"/runs",headers=headers,json={"message":"Explain", "mode":"ask"}).json()["run_id"]
    assert api("GET",path+f"/runs/{ask}",headers=headers).json()["reply"] == json.dumps(output)
    assert api("POST",path+"/runs",headers=headers,json={"message":"Edit", "mode":"edit"}).status_code == 403
    output = {"schema_version":1,"type":"clarification","message":"Which?"}
    clarify = api("POST",path+"/runs",headers=headers,json={"message":"Try"}).json()["run_id"]
    api("GET",path+f"/runs/{clarify}",headers=headers)
    def failed_post(*args, **kwargs):
        import httpx
        raise httpx.ConnectError("offline")
    monkeypatch.setattr(adapter.httpx, "post", failed_post)
    continuation = {"message":"My free text", "reply_to_run_id":clarify}
    assert api("POST",path+"/runs",headers=headers,json=continuation).status_code == 502
    monkeypatch.setattr(adapter.httpx, "post", post)
    assert api("POST",path+"/runs",headers=headers,json=continuation).status_code == 202



@pytest.mark.parametrize("response", [
    {"schema_version":True,"type":"answer","message":"x"},
    {"schema_version":1,"type":"answer","message":"x","proposal":{}},
    {"schema_version":1,"type":"clarification","message":"x","options":[{"id":"x","label":"A"},{"id":"x","label":"B"}]},
    {"schema_version":1,"type":"edit","message":"x","proposal":{"base_revision":2,"operations":[{"type":"set_title","title":"x"}],"summary":"x"}},
])
def test_parser_fails_closed(response):
    from vessel_service.notes.agent_response import parse_agent_response
    with pytest.raises(ProposalError):
        parse_agent_response(json.dumps(response), base_revision=1)


def test_actual_viewer_edit_cross_owner_continuation_and_stale_revision(api_factory, monkeypatch):
    from test_space_resources import _team_with_members, _headers, _document
    def configure(app):
        app.state.settings.agent_platform_url = "https://agent.test"
        app.state.settings.agent_id = "test"
        app.state.settings.agent_gateway_user_id = "test"
        app.state.settings.agent_gateway_secret = SecretStr("test")
    api = api_factory(configure_application=configure)
    space_id, (owner, _), (editor, _), (viewer, _), _ = _team_with_members(api)
    note_id = api("POST", f"/v1/spaces/{space_id}/notes", headers=_headers(owner), json={"title":"Saved", "document":_document()}).json()["note"]["note_id"]
    path = f"/v1/notes/{note_id}/agent"
    captured = []
    class Response:
        def __init__(self, payload): self.payload = payload
        def raise_for_status(self): pass
        def json(self): return self.payload
    def post(url, *, json, **kwargs):
        captured.append(json)
        return Response({"run_id":json["options"]["run_id"],"thread_id":json["thread_id"],"status":"queued"})
    output = {"schema_version":1,"type":"edit","message":"Edit", "proposal":{"base_revision":1,"operations":[{"type":"set_title","title":"Denied"}],"summary":"Change"}}
    monkeypatch.setattr("vessel_service.agent_platform.httpx.post", post)
    monkeypatch.setattr("vessel_service.agent_platform.httpx.get", lambda url, **kw: Response({"run_id":captured[-1]["options"]["run_id"],"status":"completed","output_text":json.dumps(output)}))
    viewer_run = api("POST",path+"/runs",headers=_headers(viewer),json={"message":"Change"}).json()["run_id"]
    result = api("GET",path+f"/runs/{viewer_run}",headers=_headers(viewer)).json()
    assert result["failure_code"] == "NOTE_AGENT_EDIT_FORBIDDEN"
    assert api("GET",f"/v1/notes/{note_id}/proposals",headers=_headers(viewer)).json()["proposals"] == []
    output = {"schema_version":1,"type":"clarification","message":"Which tone?"}
    clarification = api("POST",path+"/runs",headers=_headers(owner),json={"message":"Improve"}).json()["run_id"]
    api("GET",path+f"/runs/{clarification}",headers=_headers(owner))
    assert api("POST",path+"/runs",headers=_headers(editor),json={"message":"Short", "reply_to_run_id":clarification}).status_code == 404
    stale = api("POST",path+"/runs",headers=_headers(owner),json={"message":"Change"}).json()["run_id"]
    assert api("PATCH",f"/v1/notes/{note_id}",headers=_headers(owner),json={"expected_revision":1,"title":"New saved"}).status_code == 200
    output = {"schema_version":1,"type":"edit","message":"Edit", "proposal":{"base_revision":1,"operations":[{"type":"set_title","title":"Old"}],"summary":"Change"}}
    stale_result = api("GET",path+f"/runs/{stale}",headers=_headers(owner)).json()
    assert stale_result["status"] == "failed"
    assert stale_result["failure_code"] == "NOTE_REVISION_CONFLICT"


@pytest.mark.parametrize("wrap", [lambda body: "I need one detail before editing.\n" + body, lambda body: "```json\n" + body + "\n```"])
def test_parser_recovers_one_unambiguous_response_envelope(wrap):
    from vessel_service.notes.agent_response import parse_agent_response
    response = {"schema_version":1,"type":"clarification","message":"Which tone?"}
    assert parse_agent_response(wrap(json.dumps(response)), base_revision=1) == response


def test_parser_recovers_single_json_after_bracketed_prose_list():
    from vessel_service.notes.agent_response import parse_agent_response
    response = {"schema_version": 1, "type": "answer", "message": "Ready"}
    output = "Summary:\n- [source] checked\n- [1] item\n\n" + json.dumps(response)
    assert parse_agent_response(output, base_revision=1) == response


@pytest.mark.parametrize("text", [
    '{"schema_version":1,"type":"answer","message":"One"}\n{"schema_version":1,"type":"answer","message":"Two"}',
    'Preamble {"schema_version":1,"type":"answer","message":"One"} trailing text',
    '```json\n{"schema_version":1,"type":"answer","message":"One"}\n``` trailing',
    'Before {"unrelated":true} then {"schema_version":1,"type":"answer","message":"One"}',
    '["earlier response"]\n{"schema_version":1,"type":"answer","message":"One"}',
    'Before {"schema_version":1,"type":"answer","message":',
])
def test_parser_rejects_ambiguous_or_incomplete_envelopes(text):
    from vessel_service.notes.agent_response import parse_agent_response
    with pytest.raises(ProposalError):
        parse_agent_response(text, base_revision=1)


@pytest.mark.parametrize("current_state", ["interrupted", "running", "wrong_thread"])
def test_new_request_releases_only_owned_interrupted_run_before_start(api_factory, monkeypatch, current_state):
    import httpx
    def configure(app):
        app.state.settings.agent_platform_url = 'https://agent.test'
        app.state.settings.agent_id = 'test'
        app.state.settings.agent_gateway_user_id = 'test'
        app.state.settings.agent_gateway_secret = SecretStr('test')
    api = api_factory(configure_application=configure)
    auth = api('POST','/v1/auth/register',json={'name':'Owner','email':'interrupted@example.test','password':'test-password-123'})
    headers={'Authorization':f"Bearer {auth.json()['access_token']}"}
    note=api('POST','/v1/notes',headers=headers,json={'title':'Draft','document':{'type':'doc','schema_version':1,'content':[]}}).json()['note']
    path=f"/v1/notes/{note['note_id']}/agent"
    calls=[]; starts=[]; reads=[]
    class Response:
        def __init__(self,payload):self.payload=payload
        def raise_for_status(self):pass
        def json(self):return self.payload
    def post(url,*,json=None,**kw):
        calls.append(url)
        if url.endswith('/cancel'):
            return Response({'status':'cancelled'})
        if starts and not any(item.endswith('/cancel') for item in calls):
            return httpx.Response(409,json={'detail':{'code':'PLAN_EXECUTION_THREAD_BUSY'}},request=httpx.Request('POST',url))
        starts.append(json)
        return Response({'run_id':json['options']['run_id'],'thread_id':json['thread_id'],'status':'queued'})
    def get(url,**kw):
        reads.append(url)
        return Response({'run_id':starts[0]['options']['run_id'],'thread_id':('another-thread' if current_state == 'wrong_thread' and len(reads)>1 else starts[0]['thread_id']),'status':('running' if current_state == 'running' and len(reads)>1 else 'interrupted_max_rounds')})
    monkeypatch.setattr('vessel_service.agent_platform.httpx.post',post)
    monkeypatch.setattr('vessel_service.agent_platform.httpx.get',get)
    first=api('POST',path+'/runs',headers=headers,json={'message':'Research matches'}).json()['run_id']
    terminal=api('GET',path+'/runs/'+first,headers=headers)
    assert terminal.json()['status']=='interrupted_max_rounds'
    second=api('POST',path+'/runs',headers=headers,json={'message':'Retry research'})
    if current_state != "interrupted":
        assert second.status_code == (409 if current_state == "running" else 502), second.text
        assert not any(url.endswith("/cancel") for url in calls)
        return
    assert second.status_code==202,second.text
    assert calls[1].endswith('/'+first+'/cancel')
    assert api('GET',path+'/runs/'+first,headers=headers).json()['status']=='cancelled'
