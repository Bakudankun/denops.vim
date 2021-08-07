let s:registry = {}

function! denops#callback#add(callback) abort
  let id = sha256(string(get(a:callback, 'func')))
  let s:registry[id] = a:callback
  return id
endfunction

function! denops#callback#remove(id) abort
  if !has_key(s:registry, a:id)
    return
  endif
  silent unlet s:registry[a:id]
endfunction

function! denops#callback#call(id, ...) abort
  if !has_key(s:registry, a:id)
    throw printf('No callback function for %s exist', a:id)
  endif
  let entry = s:registry[a:id]
  let ret = call(entry.callback, a:000)
  call denops#callback#remove(a:id)
  return ret
endfunction

function! denops#callback#clear() abort
  let s:registry = {}
endfunction
