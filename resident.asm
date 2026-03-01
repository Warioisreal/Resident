.model tiny
jumps
.286
.code
org 100h
LOCALS @@


CTRL_DOWN		equ 1dh
CTRL_UP			equ 1dh + 80h
REGS_COUNT		equ 13d				; 13 регистров


; ----Border Constants ----
TLB		equ 0c9h
TRB		equ 0bbh
HB		equ 0cdh
VB		equ 0bah
BLB		equ 0c8h
BRB		equ 0bch

; ----Text Constants----
BOX_COLOR	equ 4bh
DEF_STR		equ 0
DEF_COL		equ 0
DEF_OFFSET	equ (DEF_STR * 160d) + (DEF_COL * 2d)
DATA_WIDTH	equ 7d


Start:

Main		proc

			push 0
			pop es

			mov di, 24h

			;-----
			; mov ax, es:[di+2]				; offset
			; mov [OLD09H_OFS], ax
			; mov ax, es:[di]					; segment
			; mov [OLD09H_SEG], ax
			;-----

			mov ax, es:[di]      ; получаем offset
			mov word ptr [OLD09H], ax
			mov ax, es:[di+2]    ; получаем segment
			mov word ptr [OLD09H+2], ax

			cli
			mov es:[di], offset New09h		; смещение до новой int 09h
			mov ax, cs
			mov es:[di+2], ax				; переключаемся на .code
			sti

			mov ax, 3100h					; 31 функция без ошибок завершения
			mov dx, offset EOP

			shr dx, 4						; форматируем по 2 байта в память
			inc dx							; прибавляем 1 параграф, т.к. форматировали с целочисленным делением

			int 21h

			ret
Main		endp



New09h		proc

			push ax

			in al, 60h

			cmp al, CTRL_DOWN
			je @@handle_press

			cmp al, CTRL_UP
			je @@handle_release

			jmp @@exit

@@handle_press:
			cmp cs:[FLAG], 1
			je @@super_exit

			call SaveScreen					; сохраняем видеопамять

			push bx cx dx si di bp sp ds es ss cs

			call get_ip
get_ip:

			call PrintRegs					; выводим регистры

			mov cs:[FLAG], 1				; CTRL уже нажат

			pop es es es es ds bp bp di si dx cx bx

			; 3 раза записываем в es, чтобы проглотить cs, ip и ss
			; 2 раза записываю в BP, чтобы проглотить sp

			jmp @@super_exit

@@handle_release:
			cmp cs:[FLAG], 0
			je @@super_exit

			call RestoreScreen				; восстанавливаем видеопамять

			mov cs:[FLAG], 0				; CTRL уже отжат

			jmp @@super_exit

@@super_exit:
			in al, 61h
			mov ah, al
			or al, 80h
			out 61h, al
			xchg ah, al
			out 61h, al

			mov al, 20h
			out 20h, al

			pop ax

			iret

@@exit:
			pop ax
			; jmp dword ptr cs:[OLD09H_OFS]
			jmp dword ptr cs:[OLD09H]			; [seg|ofs]

New09h		endp


SaveScreen	proc

			push ax ds es si di cx
			; DS:[SI] = адрес видеопамяти
			mov ax, 0b800h
			mov ds, ax
			xor si, si

			; ES:[DI] = адрес буфера
			mov ax, cs
			mov es, ax
			mov di, offset BUFFER

			mov cx, 80d * 25d       ; 80 * 25 слов (2 байта)
			cld                 	; Направление копирования — вперед
			rep movsw

			pop cx di si es ds ax
			ret
SaveScreen	endp

RestoreScreen	proc

			push ax ds es si di cx
			; DS:[SI] = адрес видеопамяти
			mov ax, cs
			mov ds, ax
			mov si, offset BUFFER

			; ES:[DI] = адрес буфера
			mov ax, 0b800h
			mov es, ax
			xor di, di

			mov cx, 80d * 25d       ; 80 * 25 слов (2 байта)
			cld                 	; Направление копирования — вперед
			rep movsw

			pop cx di si es ds ax
			ret
RestoreScreen	endp

PrintRegs	proc
			push cs
			pop ds

			push bp							; сохраняем значение BP
			mov bp, sp

			add bp, 2 + 2 + (REGS_COUNT * 2 - 2)	; +2d +2d +22d (+BP_data +ret_ptr +ALL_REGS_data)

			; настройка видеопамяти
			push 0b800h						; сегмент видеопамяти
			pop es

			mov di, DEF_OFFSET
			mov ah, BOX_COLOR
			;----------------------

			push 0
			mov si, offset REG_NAMES		; SI = REG_NAMES_ptr

			; --------pushing before Pdecl proc-----------
			push TLB
			push HB
			push TRB
			push DATA_WIDTH
			push DEF_OFFSET
			; --------------------------------------------
			call DrawLine

@@print_loop:
			; блок проверок цикла и присвоений
			pop cx
											; 28 26 24 22 20 18 16 14 12 10 8  6  4
											; ax bx cx dx si di bp sp ds es ss cs ip
			mov dx, [bp]					; берём нужное значение регистра из стека
			sub bp, 2						; переносим BP на новое значение регистра (AX -> EF)

			add cx, 1						; обновляем счётчик CX для внешнего цикла
			push cx

			cmp cx, REGS_COUNT				; если CX > REGS_COUNT, выходим из цикла
			ja @@exit
			;-----------------------------------
			mov al, VB
			stosw
			lodsb					; AL = DS:[SI++]
			stosw
			lodsb					; AL = DS:[SI++]
			stosw

			mov al, '='
			stosw

			; блок с внутренним циклом
			lea bx, [HEX_TABLE]
			mov cx, 4

@@hex_loop:
			rol dx, 4				; циклический сдвиг DX влево на 4 бита

			mov al, dl
			and al, 0fh				; маскируем младшие 4 бита из 1 байта DL

			xlat					; AL = DS:[BX + AL]

			stosw

			loop @@hex_loop			; цикл на 4 символа (4 бита) из DX
			;--------------------------
			mov al, VB
			stosw

			add di, (80d - (DATA_WIDTH + 2)) * 2	; переходим на новую строчку

			jmp @@print_loop

@@exit:
			; --------pushing before Pdecl proc-----------
			push BLB
			push HB
			push BRB
			push DATA_WIDTH
			push DEF_OFFSET + 160d * (REGS_COUNT + 1)
			; --------------------------------------------
			call DrawLine

			add sp, 2						; убираем значение cx из стека

			pop bp							; возвращаем значение BP

			ret
PrintRegs	endp


;-----------------------------------
; Draw angle and horizontal parts of border (Pdecl)
; update DI
;
; Entry:	left char			bp+12d
;			horizontal char		bp+10d
;	        right char			bp+8d
;        	str_len				bp+6d
;			offset				bp+4d
; Exit: -
; Exp: 		es = 0b800h
;			ah = BOX_COLOR
; Destr: -
;-----------------------------------

DrawLine	proc

			push bp
			mov bp, sp
			push di cx ax

			mov di, [bp+4d]		; update DI

			mov al, [bp+12d]	; L_char
			stosw

			mov cx, [bp+6d]		; cx = width
			mov al, [bp+10d]	; H_char
			rep stosw

			mov al, [bp+8d]		; R_char
			stosw

			pop ax cx di
			add di, 160d
			pop bp
			ret 10
DrawLine	endp


REG_NAMES		db 'AXBXCXDXSIDIBPSPDSESSSCSIP'
HEX_TABLE		db '0123456789ABCDEF'
OLD09H			dd ?
BUFFER			db 80d * 25d * 2 dup('0')
FLAG			db 0

KBD_COUNT     	dw 0                  ; Сколько клавиш накопили
KBD_DATA_BUF  	db 64 dup(0)          ; Обычный линейный буфер на 64 клавиши


; OLD09H_SEG		dw ?
; OLD09H_OFS		dw ?
; надо ли писать dd 0?


EOP:

end Start
