(assert_invalid
  (module binary
    "\00\61\73\6d\01\00\00\00\01\84\80\80\80\00\01\60"
    "\00\00\03\82\80\80\80\00\01\00\04\84\80\80\80\00"
    "\01\6f\00\0a\0a\8d\80\80\80\00\01\87\80\80\80\00"
    "\00\41\00\11\00\00\0b"
  )
  "type mismatch"
)
