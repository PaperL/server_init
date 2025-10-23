" ─────────────────────────────
" Basic Settings
" ─────────────────────────────
set nocompatible
syntax on
filetype plugin indent on
let mapleader=" "

" Terminal and Colors
set background=dark
" Use a safe colorscheme that works well in SSH
colorscheme habamax

" Encoding
set encoding=utf-8
set fileencodings=utf-8,ucs-bom,gbk,latin1

" Line Numbers, Indentation, and Bracket Matching
set number                  " Show line numbers on the left
set smartindent             " Smart auto-indenting for new lines
set autoindent              " Copy indent from current line when starting a new line
set smarttab                " Insert spaces according to shiftwidth at the start of a line
set expandtab               " Use spaces instead of tabs (important for Python, YAML)
set tabstop=4               " Number of spaces that a <Tab> in the file counts for
set shiftwidth=4            " Number of spaces to use for each step of (auto)indent
set softtabstop=4           " Number of spaces that a <Tab> counts for while editing
set showmatch               " Highlight matching brackets when cursor is on them

" Display and Cursor
" Change cursor shape in different modes (works in most modern terminals)
" SI = INSERT mode (vertical bar), EI = NORMAL mode (block), SR = REPLACE mode
if &term =~ "xterm" || &term =~ "screen" || &term =~ "tmux"
  let &t_SI = "\e[6 q"      " Vertical bar in insert mode
  let &t_EI = "\e[2 q"      " Block in normal mode
  let &t_SR = "\e[2 q"      " Block in replace mode
endif
set cursorline              " Highlight the current line
set signcolumn=auto         " Show sign column only when there are signs to display
set scrolloff=5             " Keep 5 lines visible above/below cursor when scrolling
set sidescrolloff=8         " Keep 8 columns visible left/right of cursor
set list                    " Show invisible characters
set listchars=tab:▸\ ,trail:·,extends:»,precedes:«  " Tab=▸, trailing space=·

" Search Experience
set hlsearch                " Highlight all search matches
set incsearch               " Show matches as you type
set ignorecase              " Case-insensitive search by default
set smartcase               " But case-sensitive if search contains uppercase
nnoremap <silent> <leader>h :nohlsearch<CR>  " Press Space+h to clear search highlights

" Command Line Completion
set wildmenu
set wildmode=longest:full,full

" Split Windows
set splitbelow              " Open horizontal splits below current window
set splitright              " Open vertical splits to the right of current window
nnoremap <leader>v :vsplit<CR>  " Space+v: vertical split
nnoremap <leader>s :split<CR>   " Space+s: horizontal split (changed from h to avoid conflict)

" Status Line and File Info
set laststatus=2
set ruler
set showcmd

" Backup, Swap, and Undo
set nobackup                " Don't create backup files (~filename)
set nowritebackup           " Don't create backup before overwriting a file
set noswapfile              " Don't create swap files (.swp)
" Persistent undo: keep undo history even after closing files
if has('persistent_undo')
  set undofile
  " Create undo directory if it doesn't exist
  if !isdirectory($HOME . '/.vim/undo')
    call mkdir($HOME . '/.vim/undo', 'p', 0700)
  endif
  set undodir^=~/.vim/undo//
endif

" Performance and Interaction
set updatetime=300
set lazyredraw
set ttyfast

" System Clipboard (may not work in all SSH sessions)
" unnamed = use system clipboard on Mac, unnamedplus = use system clipboard on Linux
if has('clipboard')
  set clipboard=unnamed,unnamedplus
endif

" Mouse Support (works in most modern terminals, including SSH with proper terminal)
if has('mouse')
  set mouse=a               " Enable mouse in all modes (n=normal, v=visual, i=insert, a=all)
  " In SSH, you may need to hold Shift to select text with mouse for copying
endif

" Keep Selection After Indenting in Visual Mode
" Normally, indenting in visual mode loses the selection - this keeps it
vnoremap < <gv              " Shift left and re-select
vnoremap > >gv              " Shift right and re-select

" ─────────────────────────────
" File Type Specific Settings
" ─────────────────────────────
" These settings apply automatically when you open files of specific types
" This ensures consistent formatting for different programming languages

" Shell scripts: 4 spaces, common standard for bash/zsh scripts
autocmd FileType sh,bash,zsh setlocal tabstop=4 softtabstop=4 shiftwidth=4 expandtab

" Python: 4 spaces (PEP 8 standard - Python's official style guide)
autocmd FileType python      setlocal tabstop=4 softtabstop=4 shiftwidth=4 expandtab

" JSON: 2 spaces (more compact, easier to read nested structures)
autocmd FileType json        setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab

" YAML: 2 spaces (YAML spec requires spaces, no tabs; 2 is standard)
autocmd FileType yaml        setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab

" Makefile: MUST use real tabs (Make syntax requirement, will break with spaces!)
autocmd FileType make        setlocal noexpandtab tabstop=4 shiftwidth=4

" Auto chmod +x for shell scripts starting with shebang (#!)
" When you save a file that starts with #!/, this makes it executable automatically
autocmd BufWritePost * if getline(1) =~ '^#!' | silent! execute '!chmod +x %' | redraw! | endif

" ─────────────────────────────
" Visual Guide for Line Length
" ─────────────────────────────
" Shows a vertical line at column 80 to help keep lines short
" (Many coding standards recommend max 80 or 100 characters per line)
if exists('+colorcolumn')
  set colorcolumn=80
  highlight ColorColumn ctermbg=236 guibg=#2a2a2a
endif

" ─────────────────────────────
" Key Mappings
" ─────────────────────────────
" Note: <leader> is set to Space, so <leader>w means "Space then w"
" Note: Alt/Option key is <M-...>, Ctrl is <C-...>

" Move selected lines up/down in visual mode (VS Code style)
" Alt+Up/Down to move lines - may not work in all SSH terminals
xnoremap <M-Up>   :move '<-2<CR>gv=gv
xnoremap <M-Down> :move '>+1<CR>gv=gv

" Move current line up/down in normal mode (VS Code style)
nnoremap <M-Up>   :move .-2<CR>==
nnoremap <M-Down> :move .+1<CR>==

" Alternative line movement for SSH (using Ctrl+k/j, more compatible)
nnoremap <C-k> :move .-2<CR>==
nnoremap <C-j> :move .+1<CR>==
vnoremap <C-k> :move '<-2<CR>gv=gv
vnoremap <C-j> :move '>+1<CR>gv=gv

" Format entire file (auto-indent based on filetype rules)
" gg=G means: go to top (gg), format until bottom (=G), return to original position (``)
nnoremap <leader>= gg=G``

" Toggle relative line numbers (shows distance from current line)
" Useful for commands like "5j" (move down 5 lines)
nnoremap <leader>rn :set relativenumber!<CR>

" Toggle search highlight on/off (Space+Shift+h)
nnoremap <leader>H  :set hlsearch!<CR>

" Common file operations (faster than typing :w<Enter>)
nnoremap <leader>w :w<CR>         " Space+w: save file
nnoremap <leader>q :q<CR>         " Space+q: quit
nnoremap <leader>x :x<CR>         " Space+x: save and quit
nnoremap <leader>Q :qa!<CR>       " Space+Shift+q: quit all without saving
nnoremap <leader>U <C-r>          " Space+Shift+u: redo (opposite of undo)

" Quick window navigation (easier than Ctrl+w then h/j/k/l)
nnoremap <C-h> <C-w>h             " Ctrl+h: move to left window
nnoremap <C-l> <C-w>l             " Ctrl+l: move to right window
" Note: Ctrl+j and Ctrl+k are used for moving lines above

" Redo shortcut (opposite of u for undo)
nnoremap U <C-r>                  " U: redo
