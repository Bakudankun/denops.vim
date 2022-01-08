vim9script

def denops#job#start(args: list<string>, options: dict<any> = {}): job
  final opts = extend({
      pty: 0,
      env: {},
      on_stdout: (_, _) => 0,
      on_stderr: (_, _) => 0,
      on_exit: (_, _) => 0,
      raw_options: {},
    }, options,
  )
  return Start(args, opts)
enddef

def denops#job#stop(job: job)
  Stop(job)
enddef

if has('nvim')
  function s:start(args, options) abort
    let options = extend({
          \ 'pty': a:options.pty,
          \ 'env': a:options.env,
          \ 'on_stdout': funcref('s:on_recv', [a:options.on_stdout]),
          \ 'on_stderr': funcref('s:on_recv', [a:options.on_stderr]),
          \ 'on_exit': funcref('s:on_exit', [a:options.on_exit]),
          \}, a:options.raw_options)
    return jobstart(a:args, options)
  endfunction

  function s:stop(job) abort
    try
      call jobstop(a:job)
    catch /^Vim\%((\a\+)\)\=:E900/
      " NOTE:
      " Vim does not raise exception even the job has already closed so fail
      " silently for 'E900: Invalid job id' exception
    endtry
  endfunction

  function s:on_recv(callback, job, data, event) abort
    call a:callback(join(a:data, "\n"))
  endfunction

  function s:on_exit(callback, job, status, event) abort
    call a:callback(a:status)
  endfunction
else
  # https://github.com/neovim/neovim/blob/f629f83/src/nvim/event/process.c#L24-L26
  const KILL_TIMEOUT_MS = 2000

  def Start(args: list<string>, options: dict<any>): job
    final opts = extend({
        noblock: 1,
        pty: options.pty,
        env: options.env,
        out_cb: funcref(OutCb, [options.on_stdout]),
        err_cb: funcref(OutCb, [options.on_stderr]),
        exit_cb: funcref(ExitCb, [options.on_exit]),
      }, options.raw_options)
    return job_start(args, opts)
  enddef

  def Stop(job: job)
    job_stop(job)
    timer_start(KILL_TIMEOUT_MS, (_) => job_stop(job, 'kill'))
    # Wait until the job is actually closed
    while job_status(job) ==# 'run'
      sleep 10m
    endwhile
    redraw
  enddef

  def OutCb(Callback: func, ch: channel, msg: string)
    Callback(msg)
  enddef

  def ExitCb(Callback: func, ch: channel, status: number)
    Callback(status)
  enddef
endif

