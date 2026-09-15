"""End-to-end coding tool smoke through the isolated Swift integration server."""
import json
import time
import urllib.request

URL = 'http://127.0.0.1:18088/mcp'
HEADERS = {'Content-Type': 'application/json', 'X-FileMCP-Local-Token': 'a' * 64}

def rpc(method, params):
    payload = json.dumps({'jsonrpc': '2.0', 'id': 100, 'method': method, 'params': params}).encode()
    with urllib.request.urlopen(urllib.request.Request(URL, data=payload, headers=HEADERS), timeout=10) as response:
        value = json.load(response)
    assert 'error' not in value, value
    return value['result']

def call(name, args):
    value = rpc('tools/call', {'name': name, 'arguments': args})
    assert not value.get('isError'), value
    result = value['structuredContent']
    if name in schemas:
        assert set(result) == set(schemas[name]['required']), result
    return result

schemas = {t['name']: t['outputSchema'] for t in rpc('tools/list', {})['tools']}
for name in ('edit_file', 'apply_patch', 'workspace_context', 'start_command', 'read_command_output', 'cancel_command'):
    assert name in schemas
call('write_file', {'relative_path': 'agent-http/file.txt', 'content': 'original\r\n'})
preview = call('edit_file', {'relative_path': 'agent-http/file.txt', 'old_text': 'original', 'new_text': 'changed', 'dry_run': True})
assert not preview['applied']
call('edit_file', {'relative_path': 'agent-http/file.txt', 'old_text': 'original', 'new_text': 'changed', 'expected_sha256': preview['before_sha256']})
assert call('read_file', {'relative_path': 'agent-http/file.txt'})['result'] == 'changed\r\n'
call('write_file', {'relative_path': 'agent-http/patch.txt', 'content': 'alpha\nbeta\n'})
patch = call('apply_patch', {'changes': [{'relative_path': 'agent-http/patch.txt', 'old_text': 'alpha', 'new_text': 'ALPHA'}, {'relative_path': 'agent-http/patch.txt', 'old_text': 'beta', 'new_text': 'BETA'}]})
assert patch['file_count'] == 1 and patch['change_count'] == 2
assert call('read_file', {'relative_path': 'agent-http/patch.txt'})['result'] == 'ALPHA\nBETA\n'
assert call('workspace_context', {'path': 'agent-http'})['cwd'] == 'agent-http'
args = {'request_id': 'http-test', 'command': 'printf begin; sleep 1; printf end; exit 3'}
start = call('start_command', args)
assert call('start_command', args)['session_id'] == start['session_id']
cursor = 0
output = ''
for _ in range(150):
    page = call('read_command_output', {'session_id': start['session_id'], 'cursor': cursor})
    cursor = page['next_cursor']
    output += page['output']
    if page['state'] not in ('running', 'stopping') and not page['has_more']:
        break
    time.sleep(0.03)
else:
    raise AssertionError('command did not complete')
assert output == 'beginend' and page['exit_code'] == 3, page
print('agent-tools-http: ok')
