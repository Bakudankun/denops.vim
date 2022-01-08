vim9script

const script = denops#util#script_path('@denops-private', 'cli.ts')
const engine = has('nvim') ? 'nvim' : 'vim'
var vim_exiting = false
var stopped_on_purpose = false
var job: job
var chan: channel
var NO_JOB: job
lockvar NO_JOB
var NO_CHANNEL: channel
lockvar NO_CHANNEL
const STATUS_STOPPED = 'stopped'
const STATUS_STARTING = 'starting'
const STATUS_RUNNING = 'running'

def denops#server#start()
  if g:denops#disabled
    return
  elseif denops#server#status() != STATUS_STOPPED
    denops#util#debug('Server is already starting or running. Skip')
    return
  endif
  var args: list<string> = [g:denops#server#deno, 'run']
  args += g:denops#server#deno_args
  args += [
    script,
    '--mode=' .. engine,
  ]
  if g:denops#trace
    args += ['--trace']
  endif
  const raw_options = has('nvim')
    ? {}
    : { mode: 'nl' }
  stopped_on_purpose = false
  chan = NO_CHANNEL
  job = denops#job#start(args, {
    env: {
      NO_COLOR: 1,
    },
    on_stdout: OnStdout,
    on_stderr: OnStderr,
    on_exit: OnExit,
    raw_options: raw_options,
  })
  denops#util#debug(printf('Server spawned: %s', args))
  doautocmd <nomodeline> User DenopsStarted
enddef

def denops#server#stop()
  if !!job
    stopped_on_purpose = true
    denops#job#stop(job)
  endif
enddef

def denops#server#restart()
  denops#server#stop()
  denops#server#start()
enddef

def denops#server#status(): string
  if !!job && !!chan
    return STATUS_RUNNING
  elseif !!job
    return STATUS_STARTING
  else
    return STATUS_STOPPED
  endif
enddef

def denops#server#notify(method: string, params: list<any>)
  if g:denops#disabled
    return
  elseif denops#server#status() != STATUS_RUNNING
    throw printf('The server is not ready yet')
  endif
  Notify(chan, method, params)
enddef

def denops#server#request(method: string, params: list<any>): any
  if g:denops#disabled
    return v:null
  elseif denops#server#status() != STATUS_RUNNING
    throw printf('The server is not ready yet')
  endif
  return Request(chan, method, params)
enddef

def OnStdout(data: string)
  if !!chan
    for line in split(data, '\n')
      echomsg printf('[denops] %s', substitute(line, '\t', '    ', 'g'))
    endfor
    return
  endif
  const addr = substitute(data, '\r\?\n$', '', 'g')
  denops#util#debug(printf('Connecting to `%s`', addr))
  try
    chan = Connect(addr)
  catch
    denops#util#error(printf('Failed to connect denops server: %s', v:exception))
    denops#server#stop()
    OnStderr(data)
    return
  endtry
  doautocmd <nomodeline> User DenopsReady
enddef

def OnStderr(data: string)
  echohl ErrorMsg
  for line in split(data, '\n')
    echomsg printf('[denops] %s', substitute(line, '\t', '    ', 'g'))
  endfor
  echohl None
enddef

def OnExit(status: number)
  job = NO_JOB
  chan = NO_CHANNEL
  denops#util#debug(printf('Server stopped: %s', status))
  doautocmd <nomodeline> User DenopsStopped
  if stopped_on_purpose || v:dying || !!v:exiting || vim_exiting
    return
  endif
  # Restart asynchronously to avoid #136
  timer_start(g:denops#server#restart_delay, () => Restart(status))
enddef

def Restart(status: number)
  if RestartGuard()
    return
  endif
  denops#util#warn(printf(
    'Server stopped (%d). Restarting...',
    status,
  ))
  denops#server#start()
  denops#util#info('Server is restarted.')
enddef

var restart_count = 0
var reset_restart_count_delayer = 0
def RestartGuard(): number
  ++restart_count
  if restart_count >= g:denops#server#restart_threshold
    denops#util#warn(printf(
      'Server stopped %d times within %d millisec. Denops become disabled to avoid infinity restart loop.',
      g:denops#server#restart_threshold,
      g:denops#server#restart_interval,
    ))
    g:denops#disabled = 1
    return 1
  endif
  if !!reset_restart_count_delayer
    timer_stop(reset_restart_count_delayer)
  endif
  reset_restart_count_delayer = timer_start(
    g:denops#server#restart_interval,
    () => {
      restart_count = 0
    },
  )
  return 0
enddef

if has('nvim')
  function s:connect(address) abort
    let chan = sockconnect('tcp', a:address, {
          \ 'rpc': v:true,
          \})
    if chan is# 0
      throw printf('Failed to connect `%s`', a:address)
    endif
    return chan
  endfunction

  function s:notify(chan, method, params) abort
    return call('rpcnotify', [a:chan, a:method] + a:params)
  endfunction

  function s:request(chan, method, params) abort
    return call('rpcrequest', [a:chan, a:method] + a:params)
  endfunction
else
  def Connect(address: string): channel
    const ch = ch_open(address, {
        mode: 'json',
        drop: 'auto',
        noblock: 1,
        timeout: 60 * 60 * 24 * 7,
      })
    if ch_status(ch) !=# 'open'
      throw printf('Failed to connect `%s`', address)
    endif
    return ch
  enddef

  def Notify(ch: channel, method: string, params: list<any>)
    ch_sendraw(ch, json_encode([0, [method] + params]) .. "\n")
  enddef

  def Request(ch: channel, method: string, params: list<any>): any
    final [ok, err] = ch_evalexpr(ch, [method] + params)
    if type(err) != v:t_none || err != v:null
      throw err
    endif
    return ok
  enddef
endif

augroup denops_server_internal
  autocmd!
  autocmd User DenopsStarted :
  autocmd User DenopsStopped :
  autocmd User DenopsReady :
  autocmd VimLeave * vim_exiting = true
augroup END

g:denops#server#deno = get(g:, 'denops#server#deno', g:denops#deno)
g:denops#server#deno_args = get(g:, 'denops#server#deno_args', filter([
  '-q',
  g:denops#type_check ? '' : '--no-check',
  '--unstable',
  '-A',
], (_, v) => !empty(v)))
g:denops#server#restart_delay = get(g:, 'denops#server#restart_delay', 100)
g:denops#server#restart_interval = get(g:, 'denops#server#restart_interval', 10000)
g:denops#server#restart_threshold = get(g:, 'denops#server#restart_threshold', 3)
