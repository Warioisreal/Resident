.model tiny
jumps
.286
.code
org 100h
LOCALS @@


; ---- Константы ----
CTRL_DOWN       equ 1dh
CTRL_UP         equ 1dh + 80h
REGS_COUNT      equ 13d                 ; 13 регистров
BOX_COLOR       equ 4bh
DEF_STR		equ 5
DEF_COL		equ 20
DEF_OFFSET	equ (DEF_STR * 160d) + (DEF_COL * 2d)
DATA_WIDTH      equ 7d

; ---- Границы рамки (для проверки) ----
FRAME_TOP       equ DEF_STR
FRAME_BOTTOM    equ DEF_STR + REGS_COUNT + 2	; строка, следующая за нижней границей
FRAME_LEFT      equ DEF_COL
FRAME_RIGHT     equ DEF_COL + DATA_WIDTH + 2	; столбец, следующий за правой границей

; ---- Символы рамки ----
TLB             equ 0c9h
TRB             equ 0bbh
HB              equ 0cdh
VB              equ 0bah
BLB             equ 0c8h
BRB             equ 0bch


Start:

Main		proc

			push 0
			pop es

			; Сохраняем старые векторы
			mov di, 9h * 4
			mov ax, es:[di]			; получаем offset
			mov word ptr [OLD09H], ax
			mov ax, es:[di+2]		; получаем segment
			mov word ptr [OLD09H+2], ax

			mov di, 8h * 4
			mov ax, es:[di]
			mov word ptr [OLD08H], ax
			mov ax, es:[di+2]
			mov word ptr [OLD08H+2], ax

			; Устанавливаем свои
			cli
			mov di, 9h * 4
			mov word ptr es:[di], offset New09h		; смещение до новой int 09h
			mov ax, cs
			mov word ptr es:[di+2], ax				; переключаемся на .code

			mov di, 8h * 4
			mov word ptr es:[di], offset New08h		; смещение до новой int 08h
			mov ax, cs
			mov word ptr es:[di+2], ax				; переключаемся на .code
			sti

			; Завершаем и остаёмся резидентом
			mov ax, 3100h					; 31 функция без ошибок завершения
			mov dx, offset EOP
			shr dx, 4						; форматируем по 2 байта в память
			inc dx							; прибавляем 1 параграф, т.к. форматировали с целочисленным делением
			int 21h

			ret
Main		endp

; ---- Обработчик клавиатуры (int 9) ----
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

			call SaveScreen					; сохраняем фон

			push bx cx dx si di bp sp ds es ss cs

			call @@get_ip
@@get_ip:

			call MakeFrameBuffer			; формируем рамку с регистрами
			pop es es es es ds bp bp di si dx cx bx
			; 3 раза записываем в ES, чтобы проглотить CS, IP и SS
			; 2 раза записываю в BP, чтобы проглотить SP
			call PrintFrameBuffer			; выводим рамку с регистрами

			mov cs:[FLAG], 1				; CTRL уже нажат

			jmp @@super_exit

@@handle_release:
			cmp cs:[FLAG], 0
			je @@super_exit

			call RestoreScreen				; восстанавливаем видеопамять

			mov cs:[FLAG], 0				; CTRL уже отжат

			jmp @@super_exit

@@super_exit:
			; Подтверждение прерывания клавиатуры
			in al, 61h
			mov ah, al
			or al, 80h
			out 61h, al
			xchg ah, al
			out 61h, al
			; EOI
			mov al, 20h
			out 20h, al

			pop ax

			iret

@@exit:
			pop ax
			; jmp dword ptr cs:[OLD09H_OFS]
			jmp dword ptr cs:[OLD09H]
			; [seg|ofs], но! [ memory: ... 00 | ofs seg | 00 ... ]

New09h		endp

; ---- Обработчик таймера (int 8) ----
New08h	proc
			push ax bx cx dx si di ds es
			; старый обработчик
			pushf
			call dword ptr cs:[OLD08H]	; вызываем стандартный 08h для других прог

			cmp cs:[FLAG], 1			; если рамки нет, то выходим
			jne @@exit

			push cs
			pop ds				; настройка сегмента данных

			mov ax, 0b800h		; сегмент видеопамяти
			mov es, ax

			mov byte ptr [FRAME_DIRTY], 0

			xor bx, bx
			mov cx, 80d*25d		; размер экрана

@@check_loop:
			mov di, bx			; записываем в DI актуальную позицию
			shl di, 1			; вычисляем в DI нужный байт

			mov ax, bx
			mov bl, 80d
			div bl				; AL = y_cor, AH = x_cor
			; деление AX на Bl с остатком -> AL = AX // Bl
			;								 AH = AX % BL
			mov dx, ax			; DX = ост|цел

			cmp dl, FRAME_TOP
			jb @@outside		; y_cor < FRAME_TOP
			cmp dl, FRAME_BOTTOM
			jae @@outside		; y_cor >= FRAME_BOTTOM
			cmp dh, FRAME_LEFT
			jb @@outside		; x_cor < FRAME_LEFT
			cmp dh, FRAME_RIGHT
			jae @@outside		; x_cor >= FRAME_RIGHT

			; ---- внутри рамки ----
			; смещение в буфере рамки: ((y_cor - FRAME_TOP) * 9 + (x_cor - FRAME_LEFT)) * 2
			; сохраняем в AX y_cor * 9
			mov al, dl			; сохраняем в AL остаток от деления
			sub al, FRAME_TOP
			mov bl, 9d
			mul bl				; AX = BL * AL
			; добавляем в AX x_cor
			mov bl, dh			; сохраняем в BL целое от деления
			sub bl, FRAME_LEFT
			xor bh, bh
			add ax, bx
			; умножаем AX на 2 для корректного смещения
			shl ax, 1

			mov si, ax			; SI = frame_offset
			; DI уже указывает на нужный байт
			mov ax, es:[di]		; сохраняем символ из видеопамяти в AX

			cmp ax, word ptr [si + BUFFER_FRAME]		; сравниваем символы

			je @@next									; если равны, то выходим

			; обновляем фон
			; в AX уже лежит наш символ
			mov word ptr [di + BUFFER_SCREEN], ax	; перезаписываем буфер фона

			mov byte ptr [FRAME_DIRTY], 1			; рамка испорчена

			jmp @@next

			; ---- снаружи рамки ----
@@outside:
			; DI уже указывает на нужный байт
			mov ax, es:[di]		; сохраняем символ из видеопамяти в AX

			cmp ax, word ptr [di + BUFFER_SCREEN]

			je @@next

			; обновляем фон
			mov word ptr [di + BUFFER_SCREEN], ax

@@next:
			mov bx, di		; восстанавливаем BX
			shr bx, 1

			inc bx			; делаем шаг цикла
			loop @@check_loop

			cmp byte ptr [FRAME_DIRTY], 1	; если не надо обновить рамку, то выходим
			jne @@exit

			call PrintFrameBuffer

@@exit:
			pop es ds di si dx cx bx ax
			iret
New08h	endp

; ---- Сохранить экран в буфер фона ----
SaveScreen	proc

			push ax cx si di ds es
			; DS:[SI] = адрес видеопамяти
			mov ax, 0b800h
			mov ds, ax
			xor si, si

			; ES:[DI] = адрес буфера
			mov ax, cs
			mov es, ax
			mov di, offset BUFFER_SCREEN

			mov cx, 80d * 25d       ; 80 * 25 слов (2 байта)
			cld                 	; Направление копирования — вперед
			rep movsw

			pop es ds di si cx ax
			ret
SaveScreen	endp

; ---- Восстановить экран из буфера фона ----
RestoreScreen	proc

			push ax cx si di ds es
			; DS:[SI] = адрес видеопамяти
			mov ax, cs
			mov ds, ax
			mov si, offset BUFFER_SCREEN

			; ES:[DI] = адрес буфера
			mov ax, 0b800h
			mov es, ax
			xor di, di

			mov cx, 80d * 25d       ; 80 * 25 слов (2 байта)
			cld                 	; Направление копирования — вперед
			rep movsw

			pop es ds di si cx ax
			ret
RestoreScreen	endp

; ---- Сформировать буфер рамки, используя значения из стека ----
MakeFrameBuffer		proc
			push bp
			mov bp, sp

			push ax bx cx dx di si es ds

			mov ax, cs
			mov ds, ax
			mov es, ax

			add bp, 2 + 2 + (REGS_COUNT * 2 - 2)	; +2d +2d +24d (+BP_data +ret_ptr +ALL_REGS_data)
			mov di, offset BUFFER_FRAME
			mov ah, BOX_COLOR
			lea bx, [HEX_TABLE]

			; Верхняя граница
			mov al, TLB
			stosw
			mov cx, DATA_WIDTH
			mov al, HB
			rep stosw
			mov al, TRB
			stosw

			mov si, offset REG_NAMES

			mov cx, REGS_COUNT
@@reg_loop:
			; Левая вертикаль
			mov al, VB
			stosw
			; Имя (2 символа)
			lodsb					; AL = DS:[SI++]
			stosw
			lodsb					; AL = DS:[SI++]
			stosw
			; '='
			mov al, '='
			stosw
											; 28 26 24 22 20 18 16 14 12 10 8  6  4
											; ax bx cx dx si di bp sp ds es ss cs ip
			mov dx, [bp]					; берём нужное значение регистра из стека
			sub bp, 2						; переносим BP на новое значение регистра (AX -> EF)

			push cx
			mov cx, 4
@@hex_loop:
			rol dx, 4				; циклический сдвиг DX влево на 4 бита
			mov al, dl
			and al, 0fh				; маскируем младшие 4 бита из 1 байта DL
			xlat					; AL = DS:[BX + AL]
			stosw

			loop @@hex_loop			; цикл на 4 символа (4 бита) из DX
			;--------------------------
			pop cx

			; Правая вертикаль
			mov al, VB
			stosw

			loop @@reg_loop

			; Нижняя граница
			mov al, BLB
			stosw
			mov cx, DATA_WIDTH
			mov al, HB
			rep stosw
			mov al, BRB
			stosw

			pop ds es si di dx cx bx ax
        	pop bp

			ret
MakeFrameBuffer		endp

; ---- Вывести рамку из буфера на экран ----
PrintFrameBuffer	proc
			push ax cx si di ds es

			mov ax, cs
			mov ds, ax
			mov si, offset BUFFER_FRAME

			mov ax, 0b800h
			mov es, ax
			mov di, DEF_OFFSET

			mov cx, REGS_COUNT + 2
@@row:
			push cx

			mov cx, DATA_WIDTH + 2
			rep movsw

			pop cx

			add di, (80d - (DATA_WIDTH + 2)) * 2	; переходим на следующую строку
			loop @@row

			pop es ds di si cx ax

			ret
PrintFrameBuffer	endp


; ---- Данные ----
REG_NAMES		db 'AXBXCXDXSIDIBPSPDSESSSCSIP'
HEX_TABLE		db '0123456789ABCDEF'
OLD09H          dd ?
OLD08H          dd ?
BUFFER_SCREEN	db 80d * 25d * 2 dup(0)
BUFFER_FRAME	db (REGS_COUNT + 2) * (DATA_WIDTH + 2) * 2 dup(0)
FLAG			db 0
FRAME_DIRTY		db 0

; надо ли писать dd 0?


EOP:

end Start
