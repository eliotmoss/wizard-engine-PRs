(module binary
  "\00\61\73\6d\01\00\00\00\01\85\80\80\80\00\01\60"
  "\01\7f\00\03\82\80\80\80\00\01\00\07\88\80\80\80"
  "\00\01\04\6d\61\69\6e\00\00\0a\9e\80\80\80\00\01"
  "\98\80\80\80\00\00\03\40\41\00\41\07\1a\41\e3\00"
  "\20\00\41\01\6b\22\00\6d\0c\00\1a\0b\0b"
)
(assert_trap (invoke "main" (i32.const 0x1)) "integer divide by zero")
(assert_trap (invoke "main" (i32.const 0x3e8)) "integer divide by zero")
(assert_trap (invoke "main" (i32.const 0x2710)) "integer divide by zero")
