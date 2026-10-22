import fcntl, os, pty, select, signal, struct, tempfile, termios, time, uuid
from pathlib import Path
resources = Path(__file__).resolve().parents[1] / 'Sources/Commander/Resources/TerminalShell'
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp); mailbox=root/'mailbox'; mailbox.mkdir()
    original=root/'config'; original.mkdir()
    # Exercise both forms of user resize hook; neither may be lost.
    trap_body='print resized >> "$COMMANDER_DIRECTORY_MAILBOX/user-resizes"'
    trap_definition=(f'TRAPWINCH() {{ {trap_body}; }}' if os.environ.get('COMMANDER_TEST_FUNCTION_TRAP')
                     else f"trap '{trap_body}' WINCH")
    (original/'.zshrc').write_text("PS1='READY> '; RPROMPT=''\n"+trap_definition+'\n')
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
    def assert_resize_frame(output):
        begin=b'\x1b[?2026h'; end=b'\x1b[?2026l'
        assert begin in output and end in output, 'Prompt relocation must use synchronized output'
        frame=output.split(begin,1)[1].split(end,1)[0]
        assert b'\x1b[9999;1H' in frame, 'Prompt must move inside the synchronized frame'
        assert b'READY>' in frame and b'\x1b]133;B\x07' in frame, 'Prompt must finish redrawing before rendering resumes'
    try:
        initial=drain(1)
        assert b'READY>' in initial, initial
        assert b'\x1b[9999;1H' in initial, 'Fresh prompt must be anchored at the bottom'
        assert b'\x1b]133;B\x07' in initial, 'Initial prompt must include input-start marker'
        for rows in [1, 40, 1, 40]:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, 120, 0, 0))
            resized=drain()
            assert_resize_frame(resized)
            assert b'\n' not in resized, 'Resizing an empty prompt must not append terminal lines'
            assert b'\x1b[9999;1H' in resized, 'SIGWINCH must move the prompt to the new bottom row'
            assert b'\x1b]133;B\x07' in resized, 'SIGWINCH redraw must end with input-start marker'
        assert len((mailbox/'user-resizes').read_text().splitlines()) >= 4, 'User SIGWINCH hook must survive integration'
        for mode in ['full', 'compact']:
            if mode == 'compact': compact()
            # Keep the cursor inside unfinished text while repeatedly resizing,
            # including width changes that wrap it across several rows.
            os.write(fd,b"printf '%s' 'resiz-value"+b'\x02'*6); drain()
            for rows, columns in [(20, 18), (45, 120), (10, 60), (50, 120)]:
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                resized=drain()
                assert_resize_frame(resized)
                assert b'\x1b[9999;1H' in resized, 'Editing prompt must follow the new bottom row'
                assert b'\x1b]133;B\x07' in resized, 'Editing redraw must include input-start marker'
            output=root/('resized-'+mode)
            os.write(fd,b"e\x05' > "+os.fsencode(output)+b'\n'); drain()
            if mode == 'compact': accept(); drain()
            assert output.read_text() == 'resize-value', 'Resize must preserve command text and editing cursor'
        # A running command owns the terminal: resizing must not inject prompt
        # positioning escapes into its output.
        os.write(fd,b'sleep 1\n'); drain(.2)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
        assert b'\x1b[9999;1H' not in drain(.2), 'Busy terminal must retain application-controlled cursor position'
        drain(1)
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
        print('PASS: directory sync, literal paths, preserved editing, busy deferral, empty/erased Enter, resize handshake, bottom-anchored resize redraws, user resize hooks, exit status, history, and multiline input')
    finally:
        os.kill(pid,signal.SIGHUP); os.waitpid(pid,0); os.close(fd)
        for handle in handles.values(): os.close(handle)
