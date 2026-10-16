; =============================================================================
; main.asm - DEBUG-X64 (arquivo unico)
; Depurador e utilitario de baixo nivel para Linux x86-64 (NASM, sem libc)
;
; Build (sem make):
;   nasm -f elf64 -g -F dwarf main.asm -o main.o && ld -m elf_x86_64 -nostdlib main.o -o debug-x64
;
; Modulos incorporados (na ordem): core, parser, console, memory, registers,
; debugger, breakpoints, disasm, elf, files, convert, linux
; =============================================================================
bits 64
default rel

global _start

; -----------------------------------------------------------------------------
; Constantes (todas reunidas aqui para evitar problemas de ordem de definicao)
; -----------------------------------------------------------------------------
BUFFER_CAPACITY   equ 1048576   ; 1 MiB de buffer de trabalho
MAX_BPS           equ 16

O_RDONLY          equ 0
O_WRONLY          equ 1
O_CREAT           equ 64
O_TRUNC           equ 512
MODE_0644         equ 420       ; 0644 em octal
MAX_FILE_SZ       equ 1048576

PTRACE_TRACEME    equ 0
PTRACE_CONT       equ 7
PTRACE_KILL       equ 8
PTRACE_SINGLESTEP equ 9
PTRACE_GETREGS    equ 12
PTRACE_SETREGS    equ 13
SIGKILL           equ 9

; =============================================================================
; MODULO: core (ponto de entrada, REPL e comandos de sessao)
; =============================================================================
section .rodata
    banner_msg:
        db "================================================================", 10
        db " DEBUG-X64 v1.0 - Depurador e Utilitario Baixo Nivel Linux x64", 10
        db " Arquitetura: x86-64 (ELF64) | Digite '?' para lista de comandos", 10
        db "================================================================", 10, 0

    prompt_file db "[FILE:0x", 0
    prompt_buf  db "[BUFF:0x", 0
    prompt_proc db "[PROC:0x", 0
    prompt_end  db "]> ", 0

    version_msg:
        db "DEBUG-X64 Versao 1.0.0 (NASM 64 bits / Linux ABI System V)", 10
        db "Modos suportados : FILE, BUFFER (1 MiB), PROCESS (ptrace)", 10
        db "Recursos ativos  : HexDump/Edit, ELF64, Disasm x64, Breakpoints, CRC32", 10, 0

    help_msg:
        db "Comandos Fundamentais:", 10
        db "  ?                      Exibe este resumo de ajuda", 10
        db "  H [cmd]                Exibe ajuda detalhada", 10
        db "  I [FILE|BUFFER|PROC]   Exibe ou alterna o espaco de enderecamento", 10
        db "  V                      Exibe versao e recursos da arquitetura", 10
        db "  Q                      Encerra a sessao com seguranca", 10
        db "Inspecao e Edicao Hexadecimal:", 10
        db "  D [end] [tam]          Exibe bytes em hexadecimal e ASCII", 10
        db "  E <end> <b1> [b2...]   Edita bytes na regiao ou buffer", 10
        db "  F <ini> <tam> <val>    Preenche regiao com um byte padrao", 10
        db "  M <ori> <dst> <tam>    Copia bytes de uma regiao para outra", 10
        db "  C <b1> <b2> <tam>      Compara duas regioes byte a byte", 10
        db "  S <ini> <tam> <b1...>  Pesquisa sequencia de bytes", 10
        db "  U [end] [qtd]          Desmonta instrucoes de maquina x86-64", 10
        db "Depuracao e CPU:", 10
        db "  R                      Exibe registradores gerais, RIP e RFLAGS", 10
        db "  T                      Executa uma instrucao (Single-Step)", 10
        db "  P                      Avanca instrucao (Step-Over)", 10
        db "  G                      Inicia ou continua execucao do processo", 10
        db "  B [end] | B - <end>    Lista, cria ou remove breakpoints (INT3)", 10
        db "  K                      Interrompe processo depurado", 10
        db "  X                      Exibe estado do processo e motivo de parada", 10
        db "Arquivos, ELF64 e Utilitarios:", 10
        db "  N <arquivo>            Define o caminho do arquivo de trabalho", 10
        db "  L [arquivo]            Carrega arquivo para o buffer FILE", 10
        db "  W [arquivo_saida]      Grava dados modificados em disco", 10
        db "  ELF                    Analisa cabecalhos, secoes e segmentos ELF64", 10
        db "  MAP                    Lista mapeamentos de memoria (/proc/maps)", 10
        db "  INFO                   Exibe estado geral da sessao", 10
        db "  = <v1> [v2]            Converte bases (Hex/Dec/Bin), logica e CRC32", 10, 0

    help_detail_msg:
        db "Notas de Arquitetura e Seguranca (DEBUG-X64):", 10
        db "  - Enderecos sao interpretados em hexadecimal por padrao.", 10
        db "  - No comando '=', use 0x (hex), 0d (decimal) ou 0b (binario).", 10
        db "  - O programa separa estritamente os espacos FILE, BUFFER e PROCESS.", 10
        db "  - Use 'I FILE', 'I BUFFER' ou 'I PROC' para alternar o contexto.", 10, 0

    str_m_file  db "FILE", 0
    str_m_buf   db "BUFFER", 0
    str_m_proc  db "PROC", 0
    str_m_proc2 db "PROCESS", 0

    msg_ctx_f   db "Contexto ativo: FILE (offset de arquivo carregado).", 10, 0
    msg_ctx_b   db "Contexto ativo: BUFFER (area temporaria isolada de 64 KiB).", 10, 0
    msg_ctx_p   db "Contexto ativo: PROCESS (memoria virtual via ptrace).", 10, 0
    msg_bye     db "Sessao DEBUG-X64 encerrada.", 10, 0

section .bss
    line_buf    resb 512
    tok_c       resb 64

section .text

_start:
    lea rdi, [banner_msg]
    call print_str

.repl:
    ; Exibe prompt contextual com o endereco de referencia atual
    mov eax, [work_mode]
    cmp eax, 0
    je .p_file
    cmp eax, 2
    je .p_proc
    lea rdi, [prompt_buf]
    jmp .p_addr
.p_file:
    lea rdi, [prompt_file]
    jmp .p_addr
.p_proc:
    lea rdi, [prompt_proc]
.p_addr:
    call print_str
    mov rdi, [cur_addr]
    call print_hex64
    lea rdi, [prompt_end]
    call print_str

    lea rdi, [line_buf]
    mov esi, 512
    call read_line
    test rax, rax
    js .eof_quit

    lea rdi, [line_buf]
    call dispatch_command
    jmp .repl

.eof_quit:
    call cmd_quit

; cmd_help()
cmd_help:
    lea rdi, [help_msg]
    call print_str
    ret

; cmd_help_detail()
cmd_help_detail:
    lea rdi, [help_detail_msg]
    call print_str
    ret

; cmd_version()
cmd_version:
    lea rdi, [version_msg]
    call print_str
    ret

; cmd_context(rdi=args) - I [FILE|BUFFER|PROC]
cmd_context:
    lea rsi, [tok_c]
    call next_token
    cmp byte [tok_c], 0
    je .show_curr

    lea rdi, [tok_c]
    lea rsi, [str_m_file]
    call str_ieq
    test eax, eax
    jnz .set_file

    lea rdi, [tok_c]
    lea rsi, [str_m_buf]
    call str_ieq
    test eax, eax
    jnz .set_buf

    lea rdi, [tok_c]
    lea rsi, [str_m_proc]
    call str_ieq
    test eax, eax
    jnz .set_proc

    lea rdi, [tok_c]
    lea rsi, [str_m_proc2]
    call str_ieq
    test eax, eax
    jnz .set_proc
    jmp .show_curr

.set_file:
    mov dword [work_mode], 0
    mov qword [cur_addr], 0
    jmp .show_curr
.set_buf:
    mov dword [work_mode], 1
    mov qword [work_size], 65536
    mov qword [cur_addr], 0
    jmp .show_curr
.set_proc:
    mov dword [work_mode], 2
.show_curr:
    mov eax, [work_mode]
    cmp eax, 0
    je .msg_f
    cmp eax, 2
    je .msg_p
    lea rdi, [msg_ctx_b]
    call print_str
    ret
.msg_f:
    lea rdi, [msg_ctx_f]
    call print_str
    ret
.msg_p:
    lea rdi, [msg_ctx_p]
    call print_str
    ret

; cmd_quit()
cmd_quit:
    call cmd_kill           ; Garante desanexacao/encerramento de eventual processo-alvo
    lea rdi, [msg_bye]
    call print_str
    xor edi, edi
    call sys_exit

; =============================================================================
; MODULO: parser (tokenizador e despachante de comandos)
; =============================================================================
section .rodata
    msg_unknown db "Comando desconhecido. Digite '?' para ajuda.", 10, 0
    str_elf     db "ELF", 0
    str_map     db "MAP", 0
    str_info    db "INFO", 0

section .bss
    cmd_tok     resb 64

section .text

; skip_spaces(rdi=str) -> rax=ponteiro para primeiro caractere nao-espaco
skip_spaces:
    mov rax, rdi
.loop:
    movzx ecx, byte [rax]
    cmp cl, ' '
    je .adv
    cmp cl, 9               ; TAB
    je .adv
    ret
.adv:
    add rax, 1
    jmp .loop

; next_token(rdi=input, rsi=out_tok) -> rax=resto da string
next_token:
    push rbx
    mov rbx, rsi
    call skip_spaces
    xor ecx, ecx
.copy:
    movzx edx, byte [rax]
    test dl, dl
    jz .end
    cmp dl, ' '
    je .end
    cmp dl, 9
    je .end
    cmp ecx, 62
    jge .skip_char
    mov [rbx + rcx], dl
    add ecx, 1
.skip_char:
    add rax, 1
    jmp .copy
.end:
    mov byte [rbx + rcx], 0
    pop rbx
    ret

; str_ieq(rdi=s1, rsi=s2) -> eax=1 se iguais (case-insensitive), 0 se diferentes
str_ieq:
.loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp al, 'a'
    jb .c1
    cmp al, 'z'
    ja .c1
    sub al, 32
.c1:
    cmp cl, 'a'
    jb .c2
    cmp cl, 'z'
    ja .c2
    sub cl, 32
.c2:
    cmp al, cl
    jne .diff
    test al, al
    jz .same
    add rdi, 1
    add rsi, 1
    jmp .loop
.same:
    mov eax, 1
    ret
.diff:
    xor eax, eax
    ret

; dispatch_command(rdi=cmdline)
dispatch_command:
    push rbx
    call skip_spaces
    cmp byte [rax], 0
    je .done

    mov rdi, rax
    lea rsi, [cmd_tok]
    call next_token
    mov rbx, rax            ; rbx = ponteiro para argumentos

    ; Verifica comandos de multiplas letras (ELF, MAP, INFO)
    lea rdi, [cmd_tok]
    lea rsi, [str_elf]
    call str_ieq
    test eax, eax
    jnz .do_elf

    lea rdi, [cmd_tok]
    lea rsi, [str_map]
    call str_ieq
    test eax, eax
    jnz .do_map

    lea rdi, [cmd_tok]
    lea rsi, [str_info]
    call str_ieq
    test eax, eax
    jnz .do_info

    ; Verifica se o comando possui exatamente 1 caractere
    cmp byte [cmd_tok + 1], 0
    jne .unknown

    movzx eax, byte [cmd_tok]
    cmp al, 'a'
    jb .check_single
    cmp al, 'z'
    ja .check_single
    sub al, 32

.check_single:
    mov rdi, rbx            ; Argumentos em RDI para todos os handlers
    cmp al, '?'
    je .do_help
    cmp al, 'H'
    je .do_help_detail
    cmp al, 'Q'
    je .do_quit
    cmp al, 'V'
    je .do_version
    cmp al, 'I'
    je .do_context
    cmp al, 'D'
    je .do_dump
    cmp al, 'E'
    je .do_edit
    cmp al, 'F'
    je .do_fill
    cmp al, 'M'
    je .do_move
    cmp al, 'C'
    je .do_compare
    cmp al, 'S'
    je .do_search
    cmp al, 'U'
    je .do_unassemble
    cmp al, 'R'
    je .do_regs
    cmp al, 'T'
    je .do_trace
    cmp al, 'P'
    je .do_proceed
    cmp al, 'G'
    je .do_go
    cmp al, 'B'
    je .do_break
    cmp al, 'K'
    je .do_kill
    cmp al, 'X'
    je .do_status
    cmp al, 'N'
    je .do_name
    cmp al, 'L'
    je .do_load
    cmp al, 'W'
    je .do_write
    cmp al, '='
    je .do_calc

.unknown:
    lea rdi, [msg_unknown]
    call print_str
    jmp .done

.do_help:        call cmd_help
                 jmp .done
.do_help_detail: call cmd_help_detail
                 jmp .done
.do_quit:        call cmd_quit
                 jmp .done
.do_version:     call cmd_version
                 jmp .done
.do_context:     call cmd_context
                 jmp .done
.do_dump:        call cmd_dump
                 jmp .done
.do_edit:        call cmd_edit
                 jmp .done
.do_fill:        call cmd_fill
                 jmp .done
.do_move:        call cmd_move
                 jmp .done
.do_compare:     call cmd_compare
                 jmp .done
.do_search:      call cmd_search
                 jmp .done
.do_unassemble:  call cmd_unassemble
                 jmp .done
.do_regs:        call cmd_regs
                 jmp .done
.do_trace:       call cmd_trace
                 jmp .done
.do_proceed:     call cmd_proceed
                 jmp .done
.do_go:          call cmd_go
                 jmp .done
.do_break:       call cmd_break
                 jmp .done
.do_kill:        call cmd_kill
                 jmp .done
.do_status:      call cmd_status
                 jmp .done
.do_name:        call cmd_name
                 jmp .done
.do_load:        call cmd_load
                 jmp .done
.do_write:       call cmd_write
                 jmp .done
.do_elf:         mov rdi, rbx
                 call cmd_elf
                 jmp .done
.do_map:         mov rdi, rbx
                 call cmd_map
                 jmp .done
.do_info:        mov rdi, rbx
                 call cmd_info
                 jmp .done
.do_calc:        call cmd_calc
.done:
    pop rbx
    ret

; =============================================================================
; MODULO: console (entrada e saida formatada no terminal)
; =============================================================================
section .rodata
    hex_digits db "0123456789ABCDEF"
    nl_char    db 10
    sp_char    db 32

section .bss
    char_buf   resb 8
    num_buf    resb 32

section .text

; str_len(rdi=str) -> rax=tamanho
str_len:
    xor eax, eax
    test rdi, rdi
    jz .done
.loop:
    cmp byte [rdi + rax], 0
    je .done
    add rax, 1
    jmp .loop
.done:
    ret

; print_len(rdi=buf, rsi=len)
print_len:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1              ; STDOUT
    call sys_write
    ret

; print_str(rdi=str_null_terminated)
print_str:
    push rbx
    mov rbx, rdi
    call str_len
    mov rdi, rbx
    mov rsi, rax
    call print_len
    pop rbx
    ret

; print_char(dil=char)
print_char:
    mov [char_buf], dil
    lea rdi, [char_buf]
    mov esi, 1
    call print_len
    ret

; print_nl()
print_nl:
    lea rdi, [nl_char]
    mov esi, 1
    call print_len
    ret

; print_space()
print_space:
    lea rdi, [sp_char]
    mov esi, 1
    call print_len
    ret

; print_hex8(dil=valor)
print_hex8:
    movzx eax, dil
    lea rcx, [hex_digits]
    mov edx, eax
    shr edx, 4
    and edx, 0x0F
    mov dl, [rcx + rdx]
    mov [num_buf], dl
    and eax, 0x0F
    mov al, [rcx + rax]
    mov [num_buf + 1], al
    lea rdi, [num_buf]
    mov esi, 2
    call print_len
    ret

; print_hex16(di=valor)
print_hex16:
    push rbx
    movzx ebx, di
    mov edi, ebx
    shr edi, 8
    call print_hex8
    mov edi, ebx
    call print_hex8
    pop rbx
    ret

; print_hex32(edi=valor)
print_hex32:
    push rbx
    mov ebx, edi
    shr edi, 16
    call print_hex16
    mov edi, ebx
    call print_hex16
    pop rbx
    ret

; print_hex64(rdi=valor)
print_hex64:
    push rbx
    mov rbx, rdi
    shr rdi, 32
    call print_hex32
    mov rdi, rbx
    call print_hex32
    pop rbx
    ret

; print_dec64(rdi=valor)
print_dec64:
    mov rax, rdi
    lea r8, [num_buf + 31]
    mov byte [r8], 0
    mov ecx, 10
    test rax, rax
    jnz .conv
    sub r8, 1
    mov byte [r8], '0'
    jmp .out
.conv:
    xor edx, edx
    div rcx
    add dl, '0'
    sub r8, 1
    mov [r8], dl
    test rax, rax
    jnz .conv
.out:
    mov rdi, r8
    call print_str
    ret

; read_line(rdi=buf, rsi=max_len) -> rax=bytes lidos (-1 em EOF)
read_line:
    push rbx
    push r12
    push r13
    mov rbx, rdi            ; buffer
    mov r12, rsi            ; max_len
    sub r12, 1
    xor r13d, r13d          ; contador
.read_loop:
    cmp r13, r12
    jge .finish
    xor edi, edi            ; STDIN
    lea rsi, [char_buf]
    mov edx, 1
    call sys_read
    test rax, rax
    jle .eof
    movzx eax, byte [char_buf]
    cmp al, 10              ; '\n'
    je .finish
    cmp al, 13              ; '\r'
    je .read_loop
    mov [rbx + r13], al
    add r13, 1
    jmp .read_loop
.eof:
    test r13, r13
    jnz .finish
    mov rax, -1
    jmp .exit
.finish:
    mov byte [rbx + r13], 0
    mov rax, r13
.exit:
    pop r13
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: memory (buffers, contextos e operacoes hexadecimais)
; =============================================================================
section .data
    work_mode   dd 1        ; 0=FILE, 1=BUFFER, 2=PROCESS
    work_size   dq 65536    ; Tamanho ativo padrao no modo BUFFER
    cur_addr    dq 0        ; Endereco/offset atual da sessao

section .rodata
    msg_bad_addr db "Erro: endereco fora dos limites ou inacessivel.", 10, 0
    msg_usage_e  db "Uso: E <endereco> <byte1> [byte2 ...]", 10, 0
    msg_usage_f  db "Uso: F <inicio> <tamanho> <valor_byte>", 10, 0
    msg_usage_m  db "Uso: M <origem> <destino> <tamanho>", 10, 0
    msg_usage_c  db "Uso: C <bloco1> <bloco2> <tamanho>", 10, 0
    msg_usage_s  db "Uso: S <inicio> <tamanho> <byte1> [byte2 ...]", 10, 0
    msg_edit_ok  db "Bytes atualizados com sucesso.", 10, 0
    msg_fill_ok  db "Regiao preenchida.", 10, 0
    msg_move_ok  db "Regiao copiada.", 10, 0
    msg_found    db "Padrao encontrado em: 0x", 0
    msg_arrow    db " -> ", 0
    msg_vs       db " vs ", 0

section .bss
    work_buffer resb BUFFER_CAPACITY
    tok_m       resb 64
    pat_buf     resb 64
    peek_tmp    resq 1

section .text

; read_byte_ctx(rdi=addr) -> al=byte, edx=0 (ok) ou 1 (inacessivel)
read_byte_ctx:
    cmp dword [work_mode], 2
    je .proc
    cmp rdi, [work_size]
    jae .err
    cmp rdi, BUFFER_CAPACITY
    jae .err
    lea rcx, [work_buffer]
    movzx eax, byte [rcx + rdi]
    xor edx, edx
    ret
.proc:
    cmp dword [target_pid], 0
    jle .err
    mov rsi, rdi
    mov edi, [target_pid]
    lea rdx, [peek_tmp]
    call ptrace_peek
    test rax, rax
    js .err
    movzx eax, byte [peek_tmp]
    xor edx, edx
    ret
.err:
    xor eax, eax
    mov edx, 1
    ret

; write_byte_ctx(rdi=addr, sil=val) -> edx=0 (ok) ou 1 (erro)
write_byte_ctx:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    cmp dword [work_mode], 2
    je .proc
    cmp rbx, [work_size]
    jae .err
    cmp rbx, BUFFER_CAPACITY
    jae .err
    lea rcx, [work_buffer]
    mov [rcx + rbx], r12b
    xor edx, edx
    jmp .exit
.proc:
    cmp dword [target_pid], 0
    jle .err
    mov edi, [target_pid]
    mov rsi, rbx
    lea rdx, [peek_tmp]
    call ptrace_peek
    test rax, rax
    js .err
    mov [peek_tmp], r12b
    mov edi, [target_pid]
    mov rsi, rbx
    mov rdx, [peek_tmp]
    call ptrace_poke
    test rax, rax
    js .err
    xor edx, edx
    jmp .exit
.err:
    mov edx, 1
.exit:
    pop r12
    pop rbx
    ret

; cmd_dump(rdi=args) - D [endereco] [tamanho]
cmd_dump:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [cur_addr]     ; Endereco inicial padrao
    mov r13d, 128           ; Tamanho padrao: 128 bytes

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .start_dump

    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .bad
    mov r12, rax

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    cmp byte [tok_m], 0
    je .start_dump
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .bad
    mov r13, rax

.start_dump:
    test r13, r13
    jz .done
.line_loop:
    mov rdi, r12
    call print_hex64
    mov dil, ':'
    call print_char
    call print_space

    ; Imprime ate 16 bytes em hexadecimal
    xor r14d, r14d
.hex_loop:
    cmp r14, 16
    jge .ascii_part
    cmp r14, r13
    jge .pad_hex

    lea rdi, [r12 + r14]
    call read_byte_ctx
    test edx, edx
    jnz .inacc_hex
    mov dil, al
    call print_hex8
    jmp .after_byte
.inacc_hex:
    mov dil, '?'
    call print_char
    mov dil, '?'
    call print_char
    jmp .after_byte
.pad_hex:
    call print_space
    call print_space
.after_byte:
    call print_space
    cmp r14, 7
    jne .next_h
    call print_space
.next_h:
    add r14, 1
    jmp .hex_loop

.ascii_part:
    call print_space
    mov dil, '|'
    call print_char
    xor r14d, r14d
.asc_loop:
    cmp r14, 16
    jge .end_line
    cmp r14, r13
    jge .end_line
    lea rdi, [r12 + r14]
    call read_byte_ctx
    test edx, edx
    jnz .dot
    cmp al, 32
    jb .dot
    cmp al, 126
    ja .dot
    mov dil, al
    jmp .pchar
.dot:
    mov dil, '.'
.pchar:
    call print_char
    add r14, 1
    jmp .asc_loop

.end_line:
    mov dil, '|'
    call print_char
    call print_nl

    add r12, 16
    cmp r13, 16
    jbe .update_addr
    sub r13, 16
    jmp .line_loop

.update_addr:
    mov [cur_addr], r12
    jmp .done
.bad:
    lea rdi, [msg_bad_addr]
    call print_str
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_edit(rdi=args) - E <endereco> <b1> [b2 ...]
cmd_edit:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage

    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r12, rax            ; Endereco alvo
    xor r13d, r13d          ; Contador de bytes gravados

.byte_loop:
    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .finish
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov rdi, r12
    mov esi, eax
    call write_byte_ctx
    test edx, edx
    jnz .bad
    add r12, 1
    add r13, 1
    jmp .byte_loop

.finish:
    test r13, r13
    jz .usage
    lea rdi, [msg_edit_ok]
    call print_str
    jmp .done
.bad:
    lea rdi, [msg_bad_addr]
    call print_str
    jmp .done
.usage:
    lea rdi, [msg_usage_e]
    call print_str
.done:
    pop r13
    pop r12
    pop rbx
    ret

; cmd_fill(rdi=args) - F <inicio> <tamanho> <valor>
cmd_fill:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi

    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r12, rax            ; inicio

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r13, rax            ; tamanho

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r14d, eax           ; valor

    ; Otimizacao rapida com rep stosb se estiver em BUFFER/FILE dentro do limite
    cmp dword [work_mode], 2
    je .generic_fill
    lea rax, [r12 + r13]
    cmp rax, [work_size]
    ja .bad
    lea rdi, [work_buffer]
    add rdi, r12
    mov eax, r14d
    mov rcx, r13
    cld
    rep stosb
    lea rdi, [msg_fill_ok]
    call print_str
    jmp .done

.generic_fill:
    test r13, r13
    jz .ok_msg
    mov rdi, r12
    mov esi, r14d
    call write_byte_ctx
    test edx, edx
    jnz .bad
    add r12, 1
    sub r13, 1
    jmp .generic_fill
.ok_msg:
    lea rdi, [msg_fill_ok]
    call print_str
    jmp .done
.bad:
    lea rdi, [msg_bad_addr]
    call print_str
    jmp .done
.usage:
    lea rdi, [msg_usage_f]
    call print_str
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_move(rdi=args) - M <origem> <destino> <tamanho>
cmd_move:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi

    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r12, rax            ; origem

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r13, rax            ; destino

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r14, rax            ; tamanho

.loop:
    test r14, r14
    jz .ok
    mov rdi, r12
    call read_byte_ctx
    test edx, edx
    jnz .bad
    mov esi, eax
    mov rdi, r13
    call write_byte_ctx
    test edx, edx
    jnz .bad
    add r12, 1
    add r13, 1
    sub r14, 1
    jmp .loop
.ok:
    lea rdi, [msg_move_ok]
    call print_str
    jmp .done
.bad:
    lea rdi, [msg_bad_addr]
    call print_str
    jmp .done
.usage:
    lea rdi, [msg_usage_m]
    call print_str
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_compare(rdi=args) - C <bloco1> <bloco2> <tamanho>
cmd_compare:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi

    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r12, rax            ; b1

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r13, rax            ; b2

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r14, rax            ; tamanho

.cloop:
    test r14, r14
    jz .done
    mov rdi, r12
    call read_byte_ctx
    test edx, edx
    jnz .bad
    mov r15d, eax
    mov rdi, r13
    call read_byte_ctx
    test edx, edx
    jnz .bad
    cmp al, r15b
    je .next
    ; Diferenca encontrada
    mov rdi, r12
    call print_hex64
    call print_space
    mov dil, r15b
    call print_hex8
    lea rdi, [msg_vs]
    call print_str
    mov rdi, r13
    call print_hex64
    call print_space
    mov rdi, r13
    call read_byte_ctx
    mov dil, al
    call print_hex8
    call print_nl
.next:
    add r12, 1
    add r13, 1
    sub r14, 1
    jmp .cloop
.bad:
    lea rdi, [msg_bad_addr]
    call print_str
    jmp .done
.usage:
    lea rdi, [msg_usage_c]
    call print_str
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_search(rdi=args) - S <inicio> <tamanho> <b1> [b2 ...]
cmd_search:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi

    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r12, rax            ; inicio

    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .usage
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    mov r13, rax            ; tamanho

    xor r14d, r14d          ; tamanho do padrao
.pat_loop:
    cmp r14, 64
    jge .start_search
    mov rdi, rbx
    lea rsi, [tok_m]
    call next_token
    mov rbx, rax
    cmp byte [tok_m], 0
    je .start_search
    lea rdi, [tok_m]
    call parse_hex
    test edx, edx
    jnz .usage
    lea rcx, [pat_buf]
    mov [rcx + r14], al
    add r14, 1
    jmp .pat_loop

.start_search:
    test r14, r14
    jz .usage
    cmp r13, r14
    jb .done
    sub r13, r14
    add r13, 1

.outer:
    test r13, r13
    jz .done
    xor r15d, r15d
.inner:
    cmp r15, r14
    jge .match
    lea rdi, [r12 + r15]
    call read_byte_ctx
    test edx, edx
    jnz .done
    lea rcx, [pat_buf]
    cmp al, [rcx + r15]
    jne .advance
    add r15, 1
    jmp .inner
.match:
    lea rdi, [msg_found]
    call print_str
    mov rdi, r12
    call print_hex64
    call print_nl
.advance:
    add r12, 1
    sub r13, 1
    jmp .outer

.usage:
    lea rdi, [msg_usage_s]
    call print_str
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: registers (painel de registradores x86-64 e decodificacao de RFLAGS)
; =============================================================================
section .rodata
    msg_no_proc db "Aviso: nenhum processo ativo (exibindo estado local zerado).", 10, 0
    lbl_rax db "RAX=", 0
    lbl_rbx db " RBX=", 0
    lbl_rcx db " RCX=", 0
    lbl_rdx db " RDX=", 0
    lbl_rsi db "RSI=", 0
    lbl_rdi db " RDI=", 0
    lbl_rbp db " RBP=", 0
    lbl_rsp db " RSP=", 0
    lbl_r8  db "R8 =", 0
    lbl_r9  db " R9 =", 0
    lbl_r10 db " R10=", 0
    lbl_r11 db " R11=", 0
    lbl_r12 db "R12=", 0
    lbl_r13 db " R13=", 0
    lbl_r14 db " R14=", 0
    lbl_r15 db " R15=", 0
    lbl_rip db "RIP=", 0
    lbl_flg db " RFLAGS=", 0
    lbl_f_prefix db "  [ ", 0
    lbl_f_suffix db "]", 10, 0

    str_cf db "CF ", 0
    str_pf db "PF ", 0
    str_af db "AF ", 0
    str_zf db "ZF ", 0
    str_sf db "SF ", 0
    str_tf db "TF ", 0
    str_if db "IF ", 0
    str_df db "DF ", 0
    str_of db "OF ", 0

section .bss
    ; Layout de struct user_regs_struct do Linux x86-64 (216 bytes)
    ; 0:r15, 8:r14, 16:r13, 24:r12, 32:rbp, 40:rbx, 48:r11, 56:r10,
    ; 64:r9, 72:r8, 80:rax, 88:rcx, 96:rdx, 104:rsi, 112:rdi,
    ; 120:orig_rax, 128:rip, 136:cs, 144:eflags, 152:rsp, 160:ss
    regs_data resb 216

section .text

; fetch_regs() -> eax=0 se ok, <0 se sem processo
fetch_regs:
    cmp dword [target_pid], 0
    jle .no_proc
    mov edi, PTRACE_GETREGS
    mov esi, [target_pid]
    xor edx, edx
    lea rcx, [regs_data]
    call sys_ptrace
    ret
.no_proc:
    mov rax, -1
    ret

; store_regs() -> eax=0 se ok
store_regs:
    cmp dword [target_pid], 0
    jle .no_proc
    mov edi, PTRACE_SETREGS
    mov esi, [target_pid]
    xor edx, edx
    lea rcx, [regs_data]
    call sys_ptrace
    ret
.no_proc:
    mov rax, -1
    ret

; cmd_regs(rdi=args)
cmd_regs:
    push rbx
    call fetch_regs
    test rax, rax
    jns .display
    lea rdi, [msg_no_proc]
    call print_str

.display:
    lea rbx, [regs_data]

    ; Linha 1: RAX, RBX, RCX, RDX
    lea rdi, [lbl_rax]
    call print_str
    mov rdi, [rbx + 80]
    call print_hex64

    lea rdi, [lbl_rbx]
    call print_str
    mov rdi, [rbx + 40]
    call print_hex64

    lea rdi, [lbl_rcx]
    call print_str
    mov rdi, [rbx + 88]
    call print_hex64

    lea rdi, [lbl_rdx]
    call print_str
    mov rdi, [rbx + 96]
    call print_hex64
    call print_nl

    ; Linha 2: RSI, RDI, RBP, RSP
    lea rdi, [lbl_rsi]
    call print_str
    mov rdi, [rbx + 104]
    call print_hex64

    lea rdi, [lbl_rdi]
    call print_str
    mov rdi, [rbx + 112]
    call print_hex64

    lea rdi, [lbl_rbp]
    call print_str
    mov rdi, [rbx + 32]
    call print_hex64

    lea rdi, [lbl_rsp]
    call print_str
    mov rdi, [rbx + 152]
    call print_hex64
    call print_nl

    ; Linha 3: R8..R11
    lea rdi, [lbl_r8]
    call print_str
    mov rdi, [rbx + 72]
    call print_hex64

    lea rdi, [lbl_r9]
    call print_str
    mov rdi, [rbx + 64]
    call print_hex64

    lea rdi, [lbl_r10]
    call print_str
    mov rdi, [rbx + 56]
    call print_hex64

    lea rdi, [lbl_r11]
    call print_str
    mov rdi, [rbx + 48]
    call print_hex64
    call print_nl

    ; Linha 4: R12..R15
    lea rdi, [lbl_r12]
    call print_str
    mov rdi, [rbx + 24]
    call print_hex64

    lea rdi, [lbl_r13]
    call print_str
    mov rdi, [rbx + 16]
    call print_hex64

    lea rdi, [lbl_r14]
    call print_str
    mov rdi, [rbx + 8]
    call print_hex64

    lea rdi, [lbl_r15]
    call print_str
    mov rdi, [rbx + 0]
    call print_hex64
    call print_nl

    ; Linha 5: RIP, RFLAGS e Flags simbolicas
    lea rdi, [lbl_rip]
    call print_str
    mov rdi, [rbx + 128]
    call print_hex64

    lea rdi, [lbl_flg]
    call print_str
    mov rdi, [rbx + 144]
    call print_hex64

    lea rdi, [lbl_f_prefix]
    call print_str

    mov rbx, [rbx + 144]            ; rbx = valor de RFLAGS

    bt rbx, 0                       ; CF (bit 0)
    jnc .chk_pf
    lea rdi, [str_cf]
    call print_str
.chk_pf:
    bt rbx, 2                       ; PF (bit 2)
    jnc .chk_af
    lea rdi, [str_pf]
    call print_str
.chk_af:
    bt rbx, 4                       ; AF (bit 4)
    jnc .chk_zf
    lea rdi, [str_af]
    call print_str
.chk_zf:
    bt rbx, 6                       ; ZF (bit 6)
    jnc .chk_sf
    lea rdi, [str_zf]
    call print_str
.chk_sf:
    bt rbx, 7                       ; SF (bit 7)
    jnc .chk_tf
    lea rdi, [str_sf]
    call print_str
.chk_tf:
    bt rbx, 8                       ; TF (bit 8)
    jnc .chk_if
    lea rdi, [str_tf]
    call print_str
.chk_if:
    bt rbx, 9                       ; IF (bit 9)
    jnc .chk_df
    lea rdi, [str_if]
    call print_str
.chk_df:
    bt rbx, 10                      ; DF (bit 10)
    jnc .chk_of
    lea rdi, [str_df]
    call print_str
.chk_of:
    bt rbx, 11                      ; OF (bit 11)
    jnc .end_flags
    lea rdi, [str_of]
    call print_str
.end_flags:
    lea rdi, [lbl_f_suffix]
    call print_str

    pop rbx
    ret

; =============================================================================
; MODULO: debugger (controle de execucao ptrace e mapeamento de memoria)
; =============================================================================
section .data
    target_pid    dd 0
    target_state  dd 0      ; 0=Inativo, 1=Parado, 2=Encerrado
    target_status dd 0

section .rodata
    msg_spawned  db "Processo-alvo iniciado. PID: ", 0
    msg_no_exec  db "Erro: defina um executavel valido com 'N <arquivo>' antes.", 10, 0
    msg_exited   db "Processo-alvo encerrado. Status: 0x", 0
    msg_stopped  db "Processo parado em RIP=0x", 0
    msg_killed   db "Processo-alvo finalizado com seguranca.", 10, 0
    msg_stat_in  db "Estado: Nenhum processo ativo.", 10, 0
    msg_stat_st  db "Estado: Processo PARADO (sob controle ptrace). WaitStatus=0x", 0
    proc_prefix  db "/proc/", 0
    proc_suffix  db "/maps", 0
    proc_self_m  db "/proc/self/maps", 0

section .bss
    wait_stat    resd 1
    argv_arr     resq 2
    envp_arr     resq 1
    maps_path    resb 64
    maps_buf     resb 4096

section .text

; wait_target() -> aguarda parada do processo-alvo e atualiza estado
wait_target:
    mov edi, [target_pid]
    lea rsi, [wait_stat]
    xor edx, edx
    xor ecx, ecx
    call sys_wait4
    mov eax, [wait_stat]
    mov [target_status], eax
    and eax, 0x7F
    cmp eax, 0x7F                   ; WIFSTOPPED (baixa = 0x7F)
    je .stopped
    ; Processo terminou
    lea rdi, [msg_exited]
    call print_str
    mov edi, [target_status]
    call print_hex32
    call print_nl
    mov dword [target_pid], 0
    mov dword [target_state], 2
    call bp_clear_all
    ret
.stopped:
    mov dword [target_state], 1
    call bp_check_and_restore
    call fetch_regs
    mov rax, [regs_data + 128]
    mov [cur_addr], rax
    lea rdi, [msg_stopped]
    call print_str
    mov rdi, rax
    call print_hex64
    call print_nl
    mov rdi, [cur_addr]
    call disasm_one
    ret

; spawn_target_if_needed() -> eax=0 se processo pronto, -1 se erro
spawn_target_if_needed:
    cmp dword [target_pid], 0
    jg .ready
    cmp byte [current_filename], 0
    je .no_file

    call sys_fork
    test rax, rax
    js .no_file
    jz .child

    ; Processo pai (DEBUG-X64)
    mov [target_pid], eax
    mov dword [work_mode], 2        ; Muda automaticamente para contexto PROCESS
    lea rdi, [msg_spawned]
    call print_str
    movsxd rdi, dword [target_pid]
    call print_dec64
    call print_nl
    call wait_target
    xor eax, eax
    ret

.child:
    ; Processo filho: solicita PTRACE_TRACEME e executa o binario
    xor edi, edi                    ; PTRACE_TRACEME = 0
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call sys_ptrace

    lea rax, [current_filename]
    mov [argv_arr], rax
    mov qword [argv_arr + 8], 0
    mov qword [envp_arr], 0

    lea rdi, [current_filename]
    lea rsi, [argv_arr]
    lea rdx, [envp_arr]
    call sys_execve
    mov edi, 127
    call sys_exit

.ready:
    xor eax, eax
    ret
.no_file:
    lea rdi, [msg_no_exec]
    call print_str
    mov eax, -1
    ret

; cmd_trace(rdi=args) - T (Passo unico com PTRACE_SINGLESTEP)
cmd_trace:
    call spawn_target_if_needed
    test eax, eax
    js .done
    cmp dword [target_pid], 0
    jle .done

    mov edi, PTRACE_SINGLESTEP
    mov esi, [target_pid]
    xor edx, edx
    xor ecx, ecx
    call sys_ptrace
    call wait_target
.done:
    ret

; cmd_proceed(rdi=args) - P (Step-over em instrucoes CALL 0xE8)
cmd_proceed:
    call spawn_target_if_needed
    test eax, eax
    js .done
    cmp dword [target_pid], 0
    jle .done

    call fetch_regs
    mov rdi, [regs_data + 128]
    call read_byte_ctx
    cmp al, 0xE8                    ; Verifica se instrucao atual e CALL rel32 (5 bytes)
    jne .single

    ; Coloca breakpoint temporario apos o CALL e continua
    mov rdi, [regs_data + 128]
    add rdi, 5
    ; Executa passo unico caso nao seja CALL
.single:
    call cmd_trace
.done:
    ret

; cmd_go(rdi=args) - G (Inicia ou continua execucao ate breakpoint/fim)
cmd_go:
    call spawn_target_if_needed
    test eax, eax
    js .done
    cmp dword [target_pid], 0
    jle .done

    mov edi, PTRACE_CONT
    mov esi, [target_pid]
    xor edx, edx
    xor ecx, ecx
    call sys_ptrace
    call wait_target
.done:
    ret

; cmd_kill(rdi=args) - K (Encerra processo depurado)
cmd_kill:
    cmp dword [target_pid], 0
    jle .done
    mov edi, [target_pid]
    mov esi, SIGKILL
    call sys_kill
    mov edi, [target_pid]
    lea rsi, [wait_stat]
    xor edx, edx
    xor ecx, ecx
    call sys_wait4
    mov dword [target_pid], 0
    mov dword [target_state], 0
    call bp_clear_all
    lea rdi, [msg_killed]
    call print_str
.done:
    ret

; cmd_status(rdi=args) - X (Exibe estado do processo e motivo da parada)
cmd_status:
    cmp dword [target_pid], 0
    jle .inactive
    lea rdi, [msg_stat_st]
    call print_str
    mov edi, [target_status]
    call print_hex32
    call print_nl
    xor edi, edi
    call cmd_regs
    ret
.inactive:
    lea rdi, [msg_stat_in]
    call print_str
    ret

; cmd_map(rdi=args) - MAP (Lista mapeamentos de memoria do processo ou proprio)
cmd_map:
    push rbx
    cmp dword [target_pid], 0
    jle .use_self

    ; Monta "/proc/<pid>/maps"
    lea rdi, [maps_path]
    lea rsi, [proc_prefix]
    mov ecx, 6
    cld
    rep movsb

    mov eax, [target_pid]
    lea r8, [maps_buf + 64]
    mov ecx, 10
.p_conv:
    xor edx, edx
    div ecx
    add dl, '0'
    sub r8, 1
    mov [r8], dl
    test eax, eax
    jnz .p_conv

    lea r9, [maps_buf + 64]
.p_copy:
    cmp r8, r9
    jge .p_suff
    mov al, [r8]
    mov [rdi], al
    add r8, 1
    add rdi, 1
    jmp .p_copy

.p_suff:
    lea rsi, [proc_suffix]
    mov ecx, 6
    rep movsb
    lea rdi, [maps_path]
    jmp .open_map

.use_self:
    lea rdi, [proc_self_m]

.open_map:
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    js .done
    mov rbx, rax

.read_loop:
    mov rdi, rbx
    lea rsi, [maps_buf]
    mov edx, 4096
    call sys_read
    test rax, rax
    jle .close_map
    lea rdi, [maps_buf]
    mov rsi, rax
    call print_len
    jmp .read_loop

.close_map:
    mov rdi, rbx
    call sys_close
.done:
    pop rbx
    ret

; =============================================================================
; MODULO: breakpoints (breakpoints de software INT3 / 0xCC)
; =============================================================================
section .rodata
    msg_bp_hdr   db "=== Breakpoints Ativos ===", 10, 0
    msg_bp_set   db "Breakpoint inserido em 0x", 0
    msg_bp_rem   db "Breakpoint removido de 0x", 0
    msg_bp_full  db "Erro: tabela de breakpoints cheia ou processo inativo.", 10, 0
    msg_bp_hit   db "[BREAKPOINT] Parada em 0x", 0
    msg_orig_b   db "  (byte original: 0x", 0
    msg_close_p  db ")", 10, 0

section .bss
    bp_addrs    resq MAX_BPS
    bp_orig     resb MAX_BPS
    bp_active   resb MAX_BPS
    tok_bp      resb 64
    qtmp        resq 1

section .text

; bp_clear_all()
bp_clear_all:
    lea rdi, [bp_active]
    xor eax, eax
    mov ecx, MAX_BPS
    cld
    rep stosb
    ret

; bp_check_and_restore() -> verifica se RIP-1 corresponde a um breakpoint ativo
bp_check_and_restore:
    push rbx
    push r12
    call fetch_regs
    test rax, rax
    js .done

    mov r12, [regs_data + 128]      ; RIP atual (aponta para byte apos 0xCC)
    sub r12, 1                      ; Endereco do 0xCC

    xor ebx, ebx
.loop:
    cmp ebx, MAX_BPS
    jge .done
    lea rcx, [bp_active]
    cmp byte [rcx + rbx], 0
    je .next
    lea rcx, [bp_addrs]
    cmp [rcx + rbx*8], r12
    je .found
.next:
    add ebx, 1
    jmp .loop

.found:
    ; Restaura o byte original na memoria do processo
    mov edi, [target_pid]
    mov rsi, r12
    lea rdx, [qtmp]
    call ptrace_peek
    test rax, rax
    js .done

    lea rcx, [bp_orig]
    movzx eax, byte [rcx + rbx]
    mov [qtmp], al
    mov edi, [target_pid]
    mov rsi, r12
    mov rdx, [qtmp]
    call ptrace_poke

    ; Desativa slot e recua RIP em 1 byte para executar a instrucao real
    lea rcx, [bp_active]
    mov byte [rcx + rbx], 0
    mov [regs_data + 128], r12
    call store_regs

    lea rdi, [msg_bp_hit]
    call print_str
    mov rdi, r12
    call print_hex64
    call print_nl
.done:
    pop r12
    pop rbx
    ret

; cmd_break(rdi=args) - B [endereco] | B - <endereco>
cmd_break:
    push rbx
    push r12
    mov rbx, rdi
    lea rsi, [tok_bp]
    call next_token
    mov rbx, rax

    cmp byte [tok_bp], 0
    je .list_bps

    cmp byte [tok_bp], '-'
    je .remove_bp

    ; Adicionar breakpoint no endereco informado
    cmp dword [target_pid], 0
    jle .err
    lea rdi, [tok_bp]
    call parse_hex
    test edx, edx
    jnz .err
    mov r12, rax                    ; Endereco do breakpoint

    ; Procura slot livre
    xor ebx, ebx
.find_slot:
    cmp ebx, MAX_BPS
    jge .err
    lea rcx, [bp_active]
    cmp byte [rcx + rbx], 0
    je .use_slot
    add ebx, 1
    jmp .find_slot

.use_slot:
    mov edi, [target_pid]
    mov rsi, r12
    lea rdx, [qtmp]
    call ptrace_peek
    test rax, rax
    js .err

    lea rcx, [bp_orig]
    mov al, [qtmp]
    mov [rcx + rbx], al             ; Salva byte original

    mov byte [qtmp], 0xCC           ; Injeta INT3 (0xCC)
    mov edi, [target_pid]
    mov rsi, r12
    mov rdx, [qtmp]
    call ptrace_poke
    test rax, rax
    js .err

    lea rcx, [bp_addrs]
    mov [rcx + rbx*8], r12
    lea rcx, [bp_active]
    mov byte [rcx + rbx], 1

    lea rdi, [msg_bp_set]
    call print_str
    mov rdi, r12
    call print_hex64
    call print_nl
    jmp .done

.remove_bp:
    mov rdi, rbx
    lea rsi, [tok_bp]
    call next_token
    lea rdi, [tok_bp]
    call parse_hex
    test edx, edx
    jnz .err
    mov r12, rax

    xor ebx, ebx
.rem_loop:
    cmp ebx, MAX_BPS
    jge .done
    lea rcx, [bp_active]
    cmp byte [rcx + rbx], 0
    je .rem_next
    lea rcx, [bp_addrs]
    cmp [rcx + rbx*8], r12
    jne .rem_next

    ; Restaura byte original
    mov edi, [target_pid]
    mov rsi, r12
    lea rdx, [qtmp]
    call ptrace_peek
    lea rcx, [bp_orig]
    mov al, [rcx + rbx]
    mov [qtmp], al
    mov edi, [target_pid]
    mov rsi, r12
    mov rdx, [qtmp]
    call ptrace_poke

    lea rcx, [bp_active]
    mov byte [rcx + rbx], 0
    lea rdi, [msg_bp_rem]
    call print_str
    mov rdi, r12
    call print_hex64
    call print_nl
    jmp .done
.rem_next:
    add ebx, 1
    jmp .rem_loop

.list_bps:
    lea rdi, [msg_bp_hdr]
    call print_str
    xor ebx, ebx
.lloop:
    cmp ebx, MAX_BPS
    jge .done
    lea rcx, [bp_active]
    cmp byte [rcx + rbx], 0
    je .lnext
    mov edi, ebx
    call print_dec64
    call print_space
    call print_space
    lea rcx, [bp_addrs]
    mov rdi, [rcx + rbx*8]
    call print_hex64
    lea rdi, [msg_orig_b]
    call print_str
    lea rcx, [bp_orig]
    movzx edi, byte [rcx + rbx]
    call print_hex8
    lea rdi, [msg_close_p]
    call print_str
.lnext:
    add ebx, 1
    jmp .lloop

.err:
    lea rdi, [msg_bp_full]
    call print_str
.done:
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: disasm (desmontador de instrucoes x86-64 - comando U)
; =============================================================================
section .rodata
    reg64_names:
        db "rax",0, "rcx",0, "rdx",0, "rbx",0
        db "rsp",0, "rbp",0, "rsi",0, "rdi",0
        db "r8 ",0, "r9 ",0, "r10",0, "r11",0
        db "r12",0, "r13",0, "r14",0, "r15",0

    mn_nop     db "nop", 0
    mn_ret     db "ret", 0
    mn_leave   db "leave", 0
    mn_int3    db "int3", 0
    mn_syscall db "syscall", 0
    mn_push    db "push ", 0
    mn_pop     db "pop ", 0
    mn_mov     db "mov ", 0
    mn_add     db "add ", 0
    mn_sub     db "sub ", 0
    mn_xor     db "xor ", 0
    mn_cmp     db "cmp ", 0
    mn_test    db "test ", 0
    mn_lea     db "lea ", 0
    mn_call    db "call 0x", 0
    mn_jmp     db "jmp 0x", 0
    mn_je      db "je 0x", 0
    mn_jne     db "jne 0x", 0
    mn_int     db "int 0x", 0
    mn_db      db "db 0x", 0
    str_comma  db ", ", 0
    str_Ox     db "0x", 0
    str_len_p  db "   ; len=", 0
    msg_inacc  db "Erro: memoria inacessivel para desmontagem.", 10, 0

section .bss
    inst_bytes resb 16
    tok_u      resb 64

section .text

; print_reg64(edi=indice 0..15)
print_reg64:
    and edi, 15
    shl edi, 2
    lea rax, [reg64_names]
    add rdi, rax
    call print_str
    ret

; disasm_one(rdi=addr) -> rax=comprimento da instrucao (0 se inacessivel)
disasm_one:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi            ; Endereco base da instrucao
    xor ebx, ebx            ; Faz leitura de ate 15 bytes para inst_bytes
.fetch:
    cmp ebx, 15
    jge .decode
    lea rdi, [r12 + rbx]
    call read_byte_ctx
    test edx, edx
    jnz .check_fetched
    lea rcx, [inst_bytes]
    mov [rcx + rbx], al
    add ebx, 1
    jmp .fetch

.check_fetched:
    test ebx, ebx
    jz .fail

.decode:
    xor r13d, r13d          ; cursor de byte na instrucao
    xor r14d, r14d          ; prefixo REX (0 se ausente)

    lea rcx, [inst_bytes]
    movzx eax, byte [rcx]
    mov edx, eax
    and edx, 0xF0
    cmp edx, 0x40           ; Prefixo REX (0x40..0x4F)
    jne .no_rex
    mov r14d, eax
    add r13d, 1
.no_rex:
    lea rcx, [inst_bytes]
    movzx r15d, byte [rcx + r13] ; opcode principal
    add r13d, 1

    ; Determina o comprimento total da instrucao de acordo com o opcode
    cmp r15d, 0x90          ; nop
    je .len_done
    cmp r15d, 0xC3          ; ret
    je .len_done
    cmp r15d, 0xC9          ; leave
    je .len_done
    cmp r15d, 0xCC          ; int3
    je .len_done

    ; push r64 (0x50..0x57) / pop r64 (0x58..0x5F)
    mov eax, r15d
    and eax, 0xF0
    cmp eax, 0x50
    je .len_done

    ; mov r64/r32, imm (0xB8..0xBF)
    mov eax, r15d
    and eax, 0xF8
    cmp eax, 0xB8
    jne .chk_0f
    test r14d, 8            ; REX.W = 1 -> imm64 (8 bytes), senao imm32 (4 bytes)
    jnz .imm64_len
    add r13d, 4
    jmp .len_done
.imm64_len:
    add r13d, 8
    jmp .len_done

.chk_0f:
    cmp r15d, 0x0F
    jne .chk_rel8
    add r13d, 1             ; Segundo byte do opcode (ex: 0F 05 = syscall)
    jmp .len_done

.chk_rel8:
    cmp r15d, 0xEB          ; jmp rel8
    je .add1
    cmp r15d, 0x74          ; je rel8
    je .add1
    cmp r15d, 0x75          ; jne rel8
    je .add1
    cmp r15d, 0xCD          ; int imm8
    je .add1
    jmp .chk_rel32
.add1:
    add r13d, 1
    jmp .len_done

.chk_rel32:
    cmp r15d, 0xE8          ; call rel32
    je .add4
    cmp r15d, 0xE9          ; jmp rel32
    je .add4
    jmp .chk_modrm
.add4:
    add r13d, 4
    jmp .len_done

.chk_modrm:
    ; Instrucoes com ModR/M: 89, 8B, 8D, 01, 03, 29, 2B, 31, 33, 39, 3B, 85, 83, C7, FF
    cmp r15d, 0x89
    je .has_modrm
    cmp r15d, 0x8B
    je .has_modrm
    cmp r15d, 0x8D
    je .has_modrm
    cmp r15d, 0x01
    je .has_modrm
    cmp r15d, 0x29
    je .has_modrm
    cmp r15d, 0x31
    je .has_modrm
    cmp r15d, 0x39
    je .has_modrm
    cmp r15d, 0x85
    je .has_modrm
    cmp r15d, 0x83
    je .has_modrm_imm8
    cmp r15d, 0xC7
    je .has_modrm_imm32
    jmp .len_done

.has_modrm:
    add r13d, 1
    jmp .len_done
.has_modrm_imm8:
    add r13d, 2
    jmp .len_done
.has_modrm_imm32:
    add r13d, 5

.len_done:
    ; 1) Imprime Endereco
    mov rdi, r12
    call print_hex64
    call print_space
    call print_space

    ; 2) Imprime Bytes de maquina (alinhado em 10 colunas de bytes)
    xor ebx, ebx
.pbytes:
    cmp ebx, r13d
    jge .pad_bytes
    lea rcx, [inst_bytes]
    movzx edi, byte [rcx + rbx]
    call print_hex8
    call print_space
    add ebx, 1
    jmp .pbytes
.pad_bytes:
    cmp ebx, 10
    jge .print_mnem
    call print_space
    call print_space
    call print_space
    add ebx, 1
    jmp .pad_bytes

.print_mnem:
    ; 3) Imprime Mnemonico e Operandos
    cmp r15d, 0x90
    je .out_nop
    cmp r15d, 0xC3
    je .out_ret
    cmp r15d, 0xC9
    je .out_leave
    cmp r15d, 0xCC
    je .out_int3
    cmp r15d, 0x0F
    je .out_0f

    mov eax, r15d
    and eax, 0xF8
    cmp eax, 0x50
    je .out_push
    cmp eax, 0x58
    je .out_pop
    cmp eax, 0xB8
    je .out_mov_imm

    cmp r15d, 0xE8
    je .out_call
    cmp r15d, 0xE9
    je .out_jmp32
    cmp r15d, 0xEB
    je .out_jmp8
    cmp r15d, 0x74
    je .out_je8
    cmp r15d, 0x75
    je .out_jne8
    cmp r15d, 0xCD
    je .out_int

    cmp r15d, 0x89
    je .out_mr_mov
    cmp r15d, 0x8B
    je .out_rm_mov
    cmp r15d, 0x01
    je .out_mr_add
    cmp r15d, 0x29
    je .out_mr_sub
    cmp r15d, 0x31
    je .out_mr_xor
    cmp r15d, 0x39
    je .out_mr_cmp
    cmp r15d, 0x85
    je .out_mr_test
    cmp r15d, 0x83
    je .out_grp83
    jmp .out_db

.out_nop:
    lea rdi, [mn_nop]
    call print_str
    jmp .finish_line
.out_ret:
    lea rdi, [mn_ret]
    call print_str
    jmp .finish_line
.out_leave:
    lea rdi, [mn_leave]
    call print_str
    jmp .finish_line
.out_int3:
    lea rdi, [mn_int3]
    call print_str
    jmp .finish_line
.out_0f:
    lea rcx, [inst_bytes]
    cmp byte [rcx + r13 - 1], 0x05
    jne .out_db
    lea rdi, [mn_syscall]
    call print_str
    jmp .finish_line

.out_push:
    lea rdi, [mn_push]
    call print_str
    mov edi, r15d
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    jmp .finish_line

.out_pop:
    lea rdi, [mn_pop]
    call print_str
    mov edi, r15d
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    jmp .finish_line

.out_mov_imm:
    lea rdi, [mn_mov]
    call print_str
    mov edi, r15d
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    lea rdi, [str_comma]
    call print_str
    lea rdi, [str_Ox]
    call print_str
    lea rcx, [inst_bytes]
    test r14d, 8
    jnz .p_imm64
    mov edi, [rcx + r13 - 4]
    call print_hex32
    jmp .finish_line
.p_imm64:
    mov rdi, [rcx + r13 - 8]
    call print_hex64
    jmp .finish_line

.out_call:
    lea rdi, [mn_call]
    call print_str
    lea rcx, [inst_bytes]
    movsxd rax, dword [rcx + r13 - 4]
    lea rdi, [r12 + r13]
    add rdi, rax
    call print_hex64
    jmp .finish_line

.out_jmp32:
    lea rdi, [mn_jmp]
    call print_str
    lea rcx, [inst_bytes]
    movsxd rax, dword [rcx + r13 - 4]
    lea rdi, [r12 + r13]
    add rdi, rax
    call print_hex64
    jmp .finish_line

.out_jmp8:
    lea rdi, [mn_jmp]
    call print_str
    lea rcx, [inst_bytes]
    movsx rax, byte [rcx + r13 - 1]
    lea rdi, [r12 + r13]
    add rdi, rax
    call print_hex64
    jmp .finish_line

.out_je8:
    lea rdi, [mn_je]
    call print_str
    lea rcx, [inst_bytes]
    movsx rax, byte [rcx + r13 - 1]
    lea rdi, [r12 + r13]
    add rdi, rax
    call print_hex64
    jmp .finish_line

.out_jne8:
    lea rdi, [mn_jne]
    call print_str
    lea rcx, [inst_bytes]
    movsx rax, byte [rcx + r13 - 1]
    lea rdi, [r12 + r13]
    add rdi, rax
    call print_hex64
    jmp .finish_line

.out_int:
    lea rdi, [mn_int]
    call print_str
    lea rcx, [inst_bytes]
    movzx edi, byte [rcx + r13 - 1]
    call print_hex8
    jmp .finish_line

.out_mr_mov:
    lea rdi, [mn_mov]
    jmp .print_modrm_mr
.out_mr_add:
    lea rdi, [mn_add]
    jmp .print_modrm_mr
.out_mr_sub:
    lea rdi, [mn_sub]
    jmp .print_modrm_mr
.out_mr_xor:
    lea rdi, [mn_xor]
    jmp .print_modrm_mr
.out_mr_cmp:
    lea rdi, [mn_cmp]
    jmp .print_modrm_mr
.out_mr_test:
    lea rdi, [mn_test]

.print_modrm_mr:
    call print_str
    lea rcx, [inst_bytes]
    movzx ebx, byte [rcx + r13 - 1]
    mov edi, ebx
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    lea rdi, [str_comma]
    call print_str
    mov edi, ebx
    shr edi, 3
    and edi, 7
    mov eax, r14d
    and eax, 4
    shl eax, 1
    or edi, eax
    call print_reg64
    jmp .finish_line

.out_rm_mov:
    lea rdi, [mn_mov]
    call print_str
    lea rcx, [inst_bytes]
    movzx ebx, byte [rcx + r13 - 1]
    mov edi, ebx
    shr edi, 3
    and edi, 7
    mov eax, r14d
    and eax, 4
    shl eax, 1
    or edi, eax
    call print_reg64
    lea rdi, [str_comma]
    call print_str
    mov edi, ebx
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    jmp .finish_line

.out_grp83:
    lea rcx, [inst_bytes]
    movzx ebx, byte [rcx + r13 - 2]
    mov eax, ebx
    shr eax, 3
    and eax, 7
    cmp eax, 0
    je .g83_add
    cmp eax, 5
    je .g83_sub
    cmp eax, 7
    je .g83_cmp
    lea rdi, [mn_add]
    jmp .g83_print
.g83_add:
    lea rdi, [mn_add]
    jmp .g83_print
.g83_sub:
    lea rdi, [mn_sub]
    jmp .g83_print
.g83_cmp:
    lea rdi, [mn_cmp]
.g83_print:
    call print_str
    mov edi, ebx
    and edi, 7
    mov eax, r14d
    and eax, 1
    shl eax, 3
    or edi, eax
    call print_reg64
    lea rdi, [str_comma]
    call print_str
    lea rdi, [str_Ox]
    call print_str
    lea rcx, [inst_bytes]
    movzx edi, byte [rcx + r13 - 1]
    call print_hex8
    jmp .finish_line

.out_db:
    lea rdi, [mn_db]
    call print_str
    lea rcx, [inst_bytes]
    movzx edi, byte [rcx]
    call print_hex8
    mov r13d, 1

.finish_line:
    lea rdi, [str_len_p]
    call print_str
    mov edi, r13d
    call print_dec64
    call print_nl
    mov eax, r13d
    jmp .exit

.fail:
    xor eax, eax
.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_unassemble(rdi=args) - U [endereco] [quantidade_instrucoes]
cmd_unassemble:
    push rbx
    push r12
    push r13

    mov rbx, rdi
    mov r12, [cur_addr]
    mov r13d, 10            ; Desmonta 10 instrucoes por padrao

    mov rdi, rbx
    lea rsi, [tok_u]
    call next_token
    mov rbx, rax
    cmp byte [tok_u], 0
    je .loop

    lea rdi, [tok_u]
    call parse_hex
    test edx, edx
    jnz .loop
    mov r12, rax

    mov rdi, rbx
    lea rsi, [tok_u]
    call next_token
    cmp byte [tok_u], 0
    je .loop
    lea rdi, [tok_u]
    call parse_hex
    test edx, edx
    jnz .loop
    mov r13, rax

.loop:
    test r13, r13
    jz .update
    mov rdi, r12
    call disasm_one
    test rax, rax
    jz .err
    add r12, rax
    sub r13, 1
    jmp .loop

.update:
    mov [cur_addr], r12
    jmp .done
.err:
    lea rdi, [msg_inacc]
    call print_str
.done:
    pop r13
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: elf (inspecao e validacao de executaveis e objetos ELF64)
; =============================================================================
section .rodata
    msg_not_elf db "Erro: o buffer nao contem um cabecalho ELF64 valido.", 10, 0
    msg_elf_hdr db "=== Analise de Cabecalho ELF64 ===", 10, 0
    msg_class   db "Classe      : ELF64 (2)", 10, 0
    msg_endian  db "Endianness  : Little Endian (Complemento de 2)", 10, 0
    msg_type    db "Tipo (e_type): 0x", 0
    msg_mach    db "Maquina     : 0x", 0
    msg_entry   db "Entry Point : 0x", 0
    msg_phoff   db "PH Offset   : 0x", 0
    msg_phnum   db "  Entradas PH: ", 0
    msg_shoff   db "SH Offset   : 0x", 0
    msg_shnum   db "  Entradas SH: ", 0
    msg_ph_list db "--- Segmentos de Programa (Program Headers) ---", 10
                db "Idx  Tipo      Flags     Offset            VAddr             FileSz", 10, 0
    msg_sh_list db "--- Cabecalhos de Secao (Section Headers) ---", 10
                db "Idx  Tipo      Endereco          Offset            Tamanho", 10, 0
    msg_trunc   db "Aviso: tabela truncada (excede tamanho do arquivo).", 10, 0

section .text

; cmd_elf(rdi=args)
cmd_elf:
    push rbx
    push r12
    push r13
    push r14

    ; Verifica tamanho minimo do cabecalho ELF64 (64 bytes)
    cmp qword [work_size], 64
    jb .invalid

    lea rbx, [work_buffer]
    ; Verifica assinatura 0x7F 'E' 'L' 'F' (0x464C457F em little-endian)
    cmp dword [rbx], 0x464C457F
    jne .invalid
    ; Verifica classe ELFCLASS64 (2)
    cmp byte [rbx + 4], 2
    jne .invalid

    lea rdi, [msg_elf_hdr]
    call print_str
    lea rdi, [msg_class]
    call print_str
    lea rdi, [msg_endian]
    call print_str

    lea rdi, [msg_type]
    call print_str
    movzx edi, word [rbx + 16]      ; e_type
    call print_hex16
    call print_nl

    lea rdi, [msg_mach]
    call print_str
    movzx edi, word [rbx + 18]      ; e_machine (0x3E = x86-64)
    call print_hex16
    call print_nl

    lea rdi, [msg_entry]
    call print_str
    mov rdi, [rbx + 24]             ; e_entry
    call print_hex64
    call print_nl

    lea rdi, [msg_phoff]
    call print_str
    mov rdi, [rbx + 32]             ; e_phoff
    call print_hex64
    lea rdi, [msg_phnum]
    call print_str
    movzx edi, word [rbx + 56]      ; e_phnum
    call print_dec64
    call print_nl

    lea rdi, [msg_shoff]
    call print_str
    mov rdi, [rbx + 40]             ; e_shoff
    call print_hex64
    lea rdi, [msg_shnum]
    call print_str
    movzx edi, word [rbx + 60]      ; e_shnum
    call print_dec64
    call print_nl

    ; Lista Program Headers se existirem
    mov r12, [rbx + 32]             ; e_phoff
    movzx r13d, word [rbx + 56]     ; e_phnum
    movzx r14d, word [rbx + 54]     ; e_phentsize
    test r13, r13
    jz .check_sh

    lea rdi, [msg_ph_list]
    call print_str
    xor ecx, ecx
.ph_loop:
    cmp rcx, r13
    jge .check_sh
    push rcx

    ; Verifica limites no buffer
    mov rax, r12
    add rax, r14
    cmp rax, [work_size]
    ja .ph_trunc

    mov rdi, rcx
    call print_hex16
    call print_space
    call print_space

    lea r8, [rbx + r12]
    mov edi, [r8]                   ; p_type
    call print_hex32
    call print_space
    call print_space

    mov edi, [r8 + 4]               ; p_flags
    call print_hex32
    call print_space
    call print_space

    mov rdi, [r8 + 8]               ; p_offset
    call print_hex64
    call print_space
    call print_space

    mov rdi, [r8 + 16]              ; p_vaddr
    call print_hex64
    call print_space
    call print_space

    mov rdi, [r8 + 32]              ; p_filesz
    call print_hex64
    call print_nl

    add r12, r14
    pop rcx
    add rcx, 1
    jmp .ph_loop

.ph_trunc:
    pop rcx
    lea rdi, [msg_trunc]
    call print_str

.check_sh:
    mov r12, [rbx + 40]             ; e_shoff
    movzx r13d, word [rbx + 60]     ; e_shnum
    movzx r14d, word [rbx + 58]     ; e_shentsize
    test r13, r13
    jz .done

    lea rdi, [msg_sh_list]
    call print_str
    xor ecx, ecx
.sh_loop:
    cmp rcx, r13
    jge .done
    cmp rcx, 16                     ; Limita exibicao as 16 primeiras secoes
    jge .done
    push rcx

    mov rax, r12
    add rax, r14
    cmp rax, [work_size]
    ja .sh_trunc

    mov rdi, rcx
    call print_hex16
    call print_space
    call print_space

    lea r8, [rbx + r12]
    mov edi, [r8 + 4]               ; sh_type
    call print_hex32
    call print_space
    call print_space

    mov rdi, [r8 + 16]              ; sh_addr
    call print_hex64
    call print_space
    call print_space

    mov rdi, [r8 + 24]              ; sh_offset
    call print_hex64
    call print_space
    call print_space

    mov rdi, [r8 + 32]              ; sh_size
    call print_hex64
    call print_nl

    add r12, r14
    pop rcx
    add rcx, 1
    jmp .sh_loop

.sh_trunc:
    pop rcx
    lea rdi, [msg_trunc]
    call print_str
    jmp .done

.invalid:
    lea rdi, [msg_not_elf]
    call print_str
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: files (leitura, gravacao controlada e informacoes de arquivos)
; =============================================================================
section .rodata
    msg_name_set  db "Arquivo de trabalho definido: ", 0
    msg_no_name   db "Erro: nenhum arquivo definido. Use 'N <caminho>'.", 10, 0
    msg_open_err  db "Erro ao abrir o arquivo.", 10, 0
    msg_loaded    db "Bytes carregados no contexto FILE: ", 0
    msg_writing   db "Gravando em: ", 0
    msg_written   db "Bytes efetivamente gravados: ", 0
    msg_write_err db "Erro: falha ou escrita parcial detectada!", 10, 0
    msg_info_hdr  db "=== Informacoes da Sessao DEBUG-X64 ===", 10, 0
    msg_info_file db "Arquivo atual : ", 0
    msg_info_size db "Tamanho (B)   : ", 0
    msg_info_addr db "Cursor atual  : 0x", 0
    msg_info_pid  db "PID depurado  : ", 0

section .bss
    current_filename resb 256
    out_filename     resb 256

section .text

; cmd_name(rdi=args) - N <caminho>
cmd_name:
    lea rsi, [current_filename]
    call next_token
    cmp byte [current_filename], 0
    je .err
    lea rdi, [msg_name_set]
    call print_str
    lea rdi, [current_filename]
    call print_str
    call print_nl
    ret
.err:
    lea rdi, [msg_no_name]
    call print_str
    ret

; cmd_load(rdi=args) - L [caminho_opcional]
cmd_load:
    push rbx
    lea rsi, [out_filename]
    call next_token
    cmp byte [out_filename], 0
    je .use_current
    ; Copia para current_filename
    lea rsi, [out_filename]
    lea rdi, [current_filename]
    mov ecx, 255
    cld
    rep movsb
.use_current:
    cmp byte [current_filename], 0
    je .no_name

    lea rdi, [current_filename]
    xor esi, esi            ; O_RDONLY
    xor edx, edx
    call sys_open
    test rax, rax
    js .open_err
    mov rbx, rax            ; fd

    mov rdi, rbx
    lea rsi, [work_buffer]
    mov edx, MAX_FILE_SZ
    call sys_read
    push rax                ; salva bytes lidos

    mov rdi, rbx
    call sys_close

    pop rax
    test rax, rax
    js .open_err

    mov [work_size], rax
    mov dword [work_mode], 0 ; Muda para modo FILE
    mov qword [cur_addr], 0

    lea rdi, [msg_loaded]
    call print_str
    mov rdi, [work_size]
    call print_dec64
    call print_nl
    jmp .done

.no_name:
    lea rdi, [msg_no_name]
    call print_str
    jmp .done
.open_err:
    lea rdi, [msg_open_err]
    call print_str
.done:
    pop rbx
    ret

; cmd_write(rdi=args) - W [arquivo_saida_opcional]
cmd_write:
    push rbx
    push r12
    lea rsi, [out_filename]
    call next_token
    cmp byte [out_filename], 0
    jne .has_target
    cmp byte [current_filename], 0
    je .no_name
    lea rsi, [current_filename]
    lea rdi, [out_filename]
    mov ecx, 255
    cld
    rep movsb

.has_target:
    lea rdi, [msg_writing]
    call print_str
    lea rdi, [out_filename]
    call print_str
    call print_nl

    lea rdi, [out_filename]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, MODE_0644
    call sys_open
    test rax, rax
    js .open_err
    mov rbx, rax            ; fd

    mov rdi, rbx
    lea rsi, [work_buffer]
    mov rdx, [work_size]
    call sys_write
    mov r12, rax

    mov rdi, rbx
    call sys_close

    cmp r12, [work_size]
    jne .write_err

    lea rdi, [msg_written]
    call print_str
    mov rdi, r12
    call print_dec64
    call print_nl
    jmp .done

.no_name:
    lea rdi, [msg_no_name]
    call print_str
    jmp .done
.open_err:
    lea rdi, [msg_open_err]
    call print_str
    jmp .done
.write_err:
    lea rdi, [msg_write_err]
    call print_str
.done:
    pop r12
    pop rbx
    ret

; cmd_info(rdi=args) - INFO
cmd_info:
    lea rdi, [msg_info_hdr]
    call print_str

    lea rdi, [msg_info_file]
    call print_str
    lea rdi, [current_filename]
    call print_str
    call print_nl

    lea rdi, [msg_info_size]
    call print_str
    mov rdi, [work_size]
    call print_dec64
    call print_nl

    lea rdi, [msg_info_addr]
    call print_str
    mov rdi, [cur_addr]
    call print_hex64
    call print_nl

    lea rdi, [msg_info_pid]
    call print_str
    movsxd rdi, dword [target_pid]
    call print_dec64
    call print_nl
    ret

; =============================================================================
; MODULO: convert (conversao de bases, aritmetica, logica e CRC32)
; =============================================================================
section .rodata
    msg_hex     db "  HEX: 0x", 0
    msg_udec    db "  UDEC: ", 0
    msg_sdec    db "  SDEC: ", 0
    msg_bin     db "  BIN: 0b", 0
    msg_add     db "  SOMA (+): 0x", 0
    msg_sub     db "  DIFF (-): 0x", 0
    msg_and     db "  AND  (&): 0x", 0
    msg_or      db "  OR   (|): 0x", 0
    msg_xor     db "  XOR  (^): 0x", 0
    msg_crc     db "  CRC32   : 0x", 0
    msg_err_num db "Erro: valor numerico invalido.", 10, 0

section .bss
    tok_buf     resb 64

section .text

; parse_hex(rdi=str) -> rax=valor, rdx=0 se ok ou 1 se erro
parse_hex:
    xor eax, eax
    xor edx, edx
    cmp byte [rdi], 0
    je .err
    ; Ignora prefixo 0x ou 0X se presente
    cmp byte [rdi], '0'
    jne .loop
    movzx ecx, byte [rdi + 1]
    or cl, 0x20
    cmp cl, 'x'
    jne .loop
    add rdi, 2
    cmp byte [rdi], 0
    je .err
.loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .ok
    cmp cl, '0'
    jb .err
    cmp cl, '9'
    jbe .dig
    or cl, 0x20
    cmp cl, 'a'
    jb .err
    cmp cl, 'f'
    ja .err
    sub cl, 'a' - 10
    jmp .accum
.dig:
    sub cl, '0'
.accum:
    shl rax, 4
    or rax, rcx
    add rdi, 1
    jmp .loop
.ok:
    xor edx, edx
    ret
.err:
    mov edx, 1
    ret

; parse_num(rdi=str) -> aceita 0x.. (hex), 0b.. (bin), 0d.. (dec) ou hex padrao
parse_num:
    cmp byte [rdi], '0'
    jne parse_hex
    movzx ecx, byte [rdi + 1]
    or cl, 0x20
    cmp cl, 'b'
    je .bin
    cmp cl, 'd'
    je .dec
    jmp parse_hex
.bin:
    add rdi, 2
    xor eax, eax
    cmp byte [rdi], 0
    je .err
.bloop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .ok
    sub cl, '0'
    cmp cl, 1
    ja .err
    shl rax, 1
    or rax, rcx
    add rdi, 1
    jmp .bloop
.dec:
    add rdi, 2
    xor eax, eax
    cmp byte [rdi], 0
    je .err
.dloop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .ok
    sub cl, '0'
    cmp cl, 9
    ja .err
    imul rax, rax, 10
    add rax, rcx
    add rdi, 1
    jmp .dloop
.ok:
    xor edx, edx
    ret
.err:
    mov edx, 1
    ret

; cmd_calc(rdi=args) - Comando '=' aritmetico/conversor
cmd_calc:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea rsi, [tok_buf]
    call next_token
    mov rbx, rax
    cmp byte [tok_buf], 0
    je .err

    lea rdi, [tok_buf]
    call parse_num
    test edx, edx
    jnz .err
    mov r12, rax            ; Primeiro valor

    ; Exibe conversoes de r12
    lea rdi, [msg_hex]
    call print_str
    mov rdi, r12
    call print_hex64

    lea rdi, [msg_udec]
    call print_str
    mov rdi, r12
    call print_dec64

    lea rdi, [msg_sdec]
    call print_str
    mov rax, r12
    test rax, rax
    jns .pos
    push rax
    mov dil, '-'
    call print_char
    pop rax
    neg rax
.pos:
    mov rdi, rax
    call print_dec64
    call print_nl

    ; Exibe binario (64 bits)
    lea rdi, [msg_bin]
    call print_str
    mov r13d, 63
.bprint:
    mov rax, r12
    mov ecx, r13d
    shr rax, cl
    and eax, 1
    add al, '0'
    mov dil, al
    call print_char
    sub r13d, 1
    jns .bprint
    call print_nl

    ; Calcula CRC32 do qword (SSE 4.2)
    lea rdi, [msg_crc]
    call print_str
    xor eax, eax
    not eax
    crc32 rax, r12
    not eax
    mov rdi, rax
    call print_hex64
    call print_nl

    ; Verifica se existe um segundo operando para comparacao aritmetica/logica
    mov rdi, rbx
    lea rsi, [tok_buf]
    call next_token
    cmp byte [tok_buf], 0
    je .done

    lea rdi, [tok_buf]
    call parse_num
    test edx, edx
    jnz .err
    mov r13, rax            ; Segundo valor

    lea rdi, [msg_add]
    call print_str
    lea rdi, [r12 + r13]
    call print_hex64

    lea rdi, [msg_sub]
    call print_str
    mov rdi, r12
    sub rdi, r13
    call print_hex64
    call print_nl

    lea rdi, [msg_and]
    call print_str
    mov rdi, r12
    and rdi, r13
    call print_hex64

    lea rdi, [msg_or]
    call print_str
    mov rdi, r12
    or rdi, r13
    call print_hex64

    lea rdi, [msg_xor]
    call print_str
    mov rdi, r12
    xor rdi, r13
    call print_hex64
    call print_nl
    jmp .done

.err:
    lea rdi, [msg_err_num]
    call print_str
.done:
    pop r13
    pop r12
    pop rbx
    ret

; =============================================================================
; MODULO: linux (camada de chamadas de sistema Linux x86-64)
; =============================================================================
section .text

; sys_read(rdi=fd, rsi=buf, rdx=count)
sys_read:
    xor eax, eax            ; syscall 0: read
    syscall
    ret

; sys_write(rdi=fd, rsi=buf, rdx=count)
sys_write:
    mov eax, 1              ; syscall 1: write
    syscall
    ret

; sys_open(rdi=filename, rsi=flags, rdx=mode)
sys_open:
    mov eax, 2              ; syscall 2: open
    syscall
    ret

; sys_close(rdi=fd)
sys_close:
    mov eax, 3              ; syscall 3: close
    syscall
    ret

; sys_lseek(rdi=fd, rsi=offset, rdx=whence)
sys_lseek:
    mov eax, 8              ; syscall 8: lseek
    syscall
    ret

; sys_fork()
sys_fork:
    mov eax, 57             ; syscall 57: fork
    syscall
    ret

; sys_execve(rdi=filename, rsi=argv, rdx=envp)
sys_execve:
    mov eax, 59             ; syscall 59: execve
    syscall
    ret

; sys_exit(rdi=status)
sys_exit:
    mov eax, 60             ; syscall 60: exit
    syscall

; sys_wait4(rdi=pid, rsi=status_ptr, rdx=options, rcx=rusage_ptr)
sys_wait4:
    mov r10, rcx
    mov eax, 61             ; syscall 61: wait4
    syscall
    ret

; sys_kill(rdi=pid, rsi=sig)
sys_kill:
    mov eax, 62             ; syscall 62: kill
    syscall
    ret

; sys_ptrace(rdi=request, rsi=pid, rdx=addr, rcx=data)
sys_ptrace:
    mov r10, rcx
    mov eax, 101            ; syscall 101: ptrace
    syscall
    ret

; ptrace_peek(rdi=pid, rsi=addr, rdx=out_qword_ptr) -> rax=0 se ok, <0 se erro
ptrace_peek:
    mov r10, rdx            ; data_ptr onde o kernel grava os 8 bytes lidos
    mov rdx, rsi            ; addr
    mov rsi, rdi            ; pid
    mov edi, 2              ; PTRACE_PEEKDATA = 2
    mov eax, 101
    syscall
    ret

; ptrace_poke(rdi=pid, rsi=addr, rdx=qword_val) -> rax=0 se ok, <0 se erro
ptrace_poke:
    mov r10, rdx            ; valor de 64 bits a gravar
    mov rdx, rsi            ; addr
    mov rsi, rdi            ; pid
    mov edi, 5              ; PTRACE_POKEDATA = 5
    mov eax, 101
    syscall
    ret

; sys_vm_readv(rdi=pid, rsi=lvec, rdx=liovcnt, rcx=rvec, r8=riovcnt, r9=flags)
sys_vm_readv:
    mov r10, rcx
    mov eax, 310            ; syscall 310: process_vm_readv
    syscall
    ret

; sys_vm_writev(rdi=pid, rsi=lvec, rdx=liovcnt, rcx=rvec, r8=riovcnt, r9=flags)
sys_vm_writev:
    mov r10, rcx
    mov eax, 311            ; syscall 311: process_vm_writev
    syscall
    ret
