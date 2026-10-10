import os, pty, select, signal, tempfile, time, uuid
from pathlib import Path
resources = Path(__file__).resolve().parents[1] / 'Sources/CommanderUI/Resources/TerminalShell'
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp); mailbox=root/'mailbox'; mailbox.mkdir()
    original=root/'config'; original.mkdir(); (original/'.zshrc').write_text("PS1='READY> '; RPROMPT=''\n")
    first=root/'first'; first.mkdir()
    second=root/"space ' quote $(touch INJECTED)\nline"; second.mkdir()
    third=root/'third'; third.mkdir()
    os.mkfifo(mailbox/'notify'); notify=os.open(mailbox/'notify',os.O_RDWR|os.O_NONBLOCK)
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
        print('PASS: live prompt sync, literal special-character path, preserved input, deferred busy sync')
    finally:
        os.kill(pid,signal.SIGHUP); os.waitpid(pid,0); os.close(fd); os.close(notify)
