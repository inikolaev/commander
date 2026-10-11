import fcntl, os, pty, select, signal, struct, tempfile, termios, time, uuid
from pathlib import Path
resources = Path(__file__).resolve().parents[1] / 'Sources/CommanderUI/Resources/TerminalShell'
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp); mailbox=root/'mailbox'; mailbox.mkdir()
    original=root/'config'; original.mkdir(); (original/'.zshrc').write_text("PS1='READY> '; RPROMPT=''\n")
    first=root/'first'; first.mkdir()
    second=root/"space ' quote $(touch INJECTED)\nline"; second.mkdir()
    third=root/'third'; third.mkdir()
    handles = {}
    for name in ['notify', 'events', 'responses']:
        os.mkfifo(mailbox/name)
        handles[name] = os.open(mailbox/name, os.O_RDWR|os.O_NONBLOCK)
    notify=handles['notify']
    (mailbox/'mode').write_text('full')
    def events():
        data=b''
        while True:
            try: data+=os.read(handles['events'],65536)
            except BlockingIOError: break
        return data.decode().splitlines()
    def compact():
        (mailbox/'mode').write_text('compact'); os.write(notify,b'\n')
        assert b'\x1b]133;B\x07' in drain(), 'Compact prompt redraw must include input-start marker'
        events()
    def accept():
        received=events()
        execute=[line.split()[1] for line in received if line.startswith('execute ')]
        assert execute, received
        (mailbox/'mode').write_text('full')
        os.write(handles['responses'],(execute[-1]+'\n').encode())
        return received

    def request(path):
        (mailbox/'directory').write_bytes(uuid.uuid4().hex.encode()+b'\0'+os.fsencode(path)+b'\0'); os.write(notify,b'\n')
    request(first)
    pid,fd=pty.fork()
    if pid==0:
        os.environ.update(ZDOTDIR=str(resources),COMMANDER_ORIGINAL_ZDOTDIR=str(original),COMMANDER_SHELL_RESOURCES=str(resources),COMMANDER_DIRECTORY_MAILBOX=str(mailbox),TERM='xterm-256color')
        os.execv('/bin/zsh',['zsh','-d','-i'])
    def drain(seconds=.3):
        output=b''; end=time.time()+seconds
        while time.time()<end:
            if select.select([fd],[],[],max(0,end-time.time()))[0]:
                try: output+=os.read(fd,65536)
                except OSError: break
        return output
    try:
        initial=drain(1)
        assert b'READY>' in initial, initial
        assert b'\x1b[9999;1H' in initial, 'Fresh prompt must be anchored at the bottom'
        assert b'\x1b]133;B\x07' in initial, 'Initial prompt must include input-start marker'
        for rows in [1, 40, 1, 40]:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, 120, 0, 0))
            assert b'\x1b]133;B\x07' in drain(), 'SIGWINCH redraw must end with input-start marker'
        os.write(fd,b"printf '%s' '$literal'") # an unfinished input must survive sync
        drain(); request(second); drain()
        os.write(fd,b"; printf '\\n'; pwd > "+os.fsencode(root/'cwd')+b'\n'); drain()
        assert (root/'cwd').read_bytes()==os.fsencode(second)+b'\n', (root/'cwd').read_bytes()
        assert not (root/'INJECTED').exists()
        os.write(fd,b'sleep 1; pwd > '+os.fsencode(root/'busy')+b'\n'); drain(.2)
        request(third); drain(1.2)
        assert (root/'busy').read_bytes()==os.fsencode(second)+b'\n'
        os.write(fd,b'pwd > '+os.fsencode(root/'after')+b'\n'); drain()
        assert (root/'after').read_bytes()==os.fsencode(third)+b'\n'
        events()
        compact()
        os.write(fd,b'\n'); drain()
        assert 'open' in events(), 'Empty prompt must open pane selection'
        os.write(fd,b"printf SHOULD_NOT_RUN\x15\n"); drain()
        assert 'open' in events(), 'Ctrl-U must clear the authoritative buffer'
        os.write(fd,b"abc\x7f\x7f\x7f\n"); drain()
        assert 'open' in events(), 'Backspace must clear the authoritative buffer'
        os.write(fd,b"printf 'ready' > "+os.fsencode(root/'submitted')+b'\n'); drain()
        assert not (root/'submitted').exists(), 'Command must wait for expanded-layout acknowledgement'
        accept(); drain()
        assert (root/'submitted').read_text() == 'ready'
        assert 'prompt 0' in events()
        compact()
        os.write(fd,b'false\n'); drain(); accept(); drain()
        assert 'prompt 1' in events(), 'Exit status must survive prompt hooks'
        compact()
        os.write(fd,b'\x1b[A\n'); drain(); accept(); drain()
        assert 'prompt 1' in events(), 'History recall must count as pending input'
        compact()
        os.write(fd,b"printf '%s' 'unfinished\n"); drain(); accept(); drain()
        assert not any(x.startswith('prompt ') for x in events()), 'Continuation must stay expanded'
        os.write(fd,b" text'\n"); drain()
        assert 'prompt 0' in events()
        print('PASS: directory sync, literal paths, preserved editing, busy deferral, empty/erased Enter, resize handshake, prompt redraw markers, exit status, history, and multiline input')
    finally:
        os.kill(pid,signal.SIGHUP); os.waitpid(pid,0); os.close(fd)
        for handle in handles.values(): os.close(handle)
