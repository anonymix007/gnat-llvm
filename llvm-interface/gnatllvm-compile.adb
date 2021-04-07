------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2021, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Errout;   use Errout;
with Exp_Util; use Exp_Util;
with Get_Targ; use Get_Targ;
with Nlists;   use Nlists;
with Opt;      use Opt;
with Restrict; use Restrict;
with Sem_Util; use Sem_Util;
with Snames;   use Snames;
with Stand;    use Stand;
with Stringt;  use Stringt;
with Table;    use Table;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Aliasing;     use GNATLLVM.Aliasing;
with GNATLLVM.Arrays;       use GNATLLVM.Arrays;
with GNATLLVM.Blocks;       use GNATLLVM.Blocks;
with GNATLLVM.Builtins;     use GNATLLVM.Builtins;
with GNATLLVM.Codegen;      use GNATLLVM.Codegen;
with GNATLLVM.Conditionals; use GNATLLVM.Conditionals;
with GNATLLVM.Conversions;  use GNATLLVM.Conversions;
with GNATLLVM.DebugInfo;    use GNATLLVM.DebugInfo;
with GNATLLVM.Environment;  use GNATLLVM.Environment;
with GNATLLVM.Exprs;        use GNATLLVM.Exprs;
with GNATLLVM.Instructions; use GNATLLVM.Instructions;
with GNATLLVM.Records;      use GNATLLVM.Records;
with GNATLLVM.Types;        use GNATLLVM.Types;
with GNATLLVM.Types.Create; use GNATLLVM.Types.Create;
with GNATLLVM.Subprograms;  use GNATLLVM.Subprograms;
with GNATLLVM.Utils;        use GNATLLVM.Utils;
with GNATLLVM.Variables;    use GNATLLVM.Variables;

with CCG; use CCG;

package body GNATLLVM.Compile is

   function Simple_Value_Action
     (N : Node_Id; Has_All : out Boolean) return Node_Id
     with Pre => Nkind (N) = N_Expression_With_Actions;
   --  If N just declares the value it returns, return the initializer
   --  of that value; otherwise return Empty.  Has_All is True if we
   --  have an N_Explicit_Dereference of the expression.

   procedure Emit_Loop_Statement (N : Node_Id)
     with Pre => Nkind (N) = N_Loop_Statement;
   --  Generate code for a loop

   function Emit_Internal
     (N          : Node_Id;
      LHS        : GL_Value := No_GL_Value;
      For_LHS    : Boolean  := False;
      Prefer_LHS : Boolean  := False) return GL_Value
     with Pre => Present (N), Post => Present (Emit_Internal'Result);
   --  Same as Emit, but push result into LValue list

   Suppress_Overflow_Depth : Int := 0;
   --  The depth of Push/Pop_Suppress_Overflow

   ------------------
   -- GNAT_To_LLVM --
   ------------------

   procedure GNAT_To_LLVM (GNAT_Root : Node_Id) is
      function Stand_Type (Size : Nat) return Entity_Id;
      --  Find a standard integer type with the specified size.  If none,
      --  return Empty.

      function Stand_Type (Size : Nat) return Entity_Id is
      begin
         if Get_Long_Long_Long_Size = Size then
            return Standard_Long_Long_Long_Integer;
         elsif Get_Long_Long_Size = Size then
            return Standard_Long_Long_Integer;
         elsif Get_Long_Size = Size then
            return Standard_Long_Integer;
         elsif Get_Int_Size = Size then
            return Standard_Integer;
         elsif Get_Short_Size = Size then
            return Standard_Short_Integer;
         elsif Get_Char_Size = Size then
            return Standard_Short_Short_Integer;
         else
            return Empty;
         end if;
      end Stand_Type;

      Size_Type   : Entity_Id;
      Int_32_Type : Entity_Id;
      Int_64_Type : Entity_Id;

   begin
      --  If we read a target config file, we may not have called our
      --  initialization yet, so do it here.

      if Context = Context_T (System.Null_Address) then
         Scan_Command_Line;
         Initialize_LLVM_Target;
      end if;

      --  If we're going to generate C code, initialize that subsystem

      if Code_Generation = Write_C then
         Initialize_C_Writing;
      end if;

      --  Get the sizes of fat and thin pointers and make some types.  This
      --  must be done after the above initialization since
      --  Get_Pointer_Size requires it.

      Thin_Pointer_Size := Get_Pointer_Size;
      Fat_Pointer_Size  := Thin_Pointer_Size * 2;
      Size_Type         := Stand_Type (Thin_Pointer_Size);
      Int_32_Type       := Stand_Type (32);
      Int_64_Type       := Stand_Type (64);

      --  We can't use a qualified expression here because that will cause
      --  a temporary to be placed in our stack and if the array is very
      --  large, it will blow our stack.

      LLVM_Info_Map := new LLVM_Info_Array (First_Node_Id .. Last_Node_Id);
      for J in LLVM_Info_Map'Range loop
         LLVM_Info_Map (J) := Empty_LLVM_Info_Id;
      end loop;

      --  Get single bit and single byte values and types, max alignmen
      --  and maximum integer size.

      BPU          := Get_Bits_Per_Unit;
      UBPU         := ULL (BPU);
      Bit_T        := Int_Ty (Nat (1));
      Byte_T       := Int_Ty (BPU);
      Max_Align    := Get_Maximum_Alignment * BPU;
      Max_Int_Size := (if   Enable_128bit_Types then +Get_Long_Long_Long_Size
                       else +Get_Long_Long_Size);

      --  We want to be able to support overaligned values, but we still need
      --  to have a maximum possible alignment to start with.  The maximum
      --  alignment in bytes supported by LLVM is actually 2 ** 29, but if
      --  we convert to an alignment in bits, which is the way we store
      --  alignments, that will overflow, so we restrict it to a value
      --  that won't overflow and then a further power of two to be safe.

      Max_Valid_Align := Nat ((ULL (Nat'Last) + 1) / UBPU / 2);

      --  We have to initialize aliasing before we create any types

      GNATLLVM.Aliasing.Initialize;

      --  We create Name_Id values for struct names

      Namet.Unlock;

      --  We must elaborate Size_Type first because its needed to elaborate
      --  all other types and we need to have a kludge here to set the sizes
      --  of the GL_Type only when the below variables have been set.

      Size_GL_Type := Primitive_GL_Type (Size_Type);
      Size_T       := Type_Of (Size_Type);
      Update_GL_Type (Size_GL_Type, Size_T, False);
      Update_GL_Type (Base_GL_Type (Size_Type), Size_T, False);

      --  Now create the 32-bit and 64-bit integer types, allowing for the
      --  possibility that we don't have a 64-bit type.

      Int_32_GL_Type := Primitive_GL_Type (Int_32_Type);
      Int_32_T       := Type_Of (Int_32_GL_Type);
      if Present (Int_64_Type) then
         Int_64_GL_Type := Primitive_GL_Type (Int_64_Type);
         Int_64_T       := Type_Of (Int_64_GL_Type);
      end if;

      --  Create GL_Types for builtin types

      A_Char_GL_Type    := Primitive_GL_Type (Standard_A_Char);
      Boolean_GL_Type   := Primitive_GL_Type (Standard_Boolean);
      SSI_GL_Type       := Primitive_GL_Type (Standard_Short_Short_Integer);
      SI_GL_Type        := Primitive_GL_Type (Standard_Short_Integer);
      Integer_GL_Type   := Primitive_GL_Type (Standard_Integer);
      LI_GL_Type        := Primitive_GL_Type (Standard_Long_Integer);
      LLI_GL_Type       := Primitive_GL_Type (Standard_Long_Long_Integer);
      Void_GL_Type      := Primitive_GL_Type (Standard_Void_Type);
      Any_Array_GL_Type := Primitive_GL_Type (Any_Array);

      --  Create a "void" pointer, which is i8* in LLVM

      Void_Ptr_T        := Type_Of (A_Char_GL_Type);

      --  Initialize modules and handle duplicate globals

      Stringt.Unlock;
      GNATLLVM.Blocks.Initialize;
      GNATLLVM.Builtins.Initialize;
      GNATLLVM.DebugInfo.Initialize;
      Detect_Duplicate_Global_Names;
      Stringt.Lock;

      --  Actually translate

      Emit (GNAT_Root);

      --   Now finalize things and generate code

      Output_Global_Constructors_Destructors;
      Add_Functions_To_Module;
      Finalize_Debugging;
      Generate_Code (GNAT_Root);
      Namet.Lock;

   end GNAT_To_LLVM;

   ---------------------------
   -- Push_Supress_Overflow --
   ---------------------------

   procedure Push_Suppress_Overflow is
   begin
      Suppress_Overflow_Depth := Suppress_Overflow_Depth + 1;
   end Push_Suppress_Overflow;

   ---------------------------
   -- Push_Supress_Overflow --
   ---------------------------

   procedure Pop_Suppress_Overflow is
   begin
      Suppress_Overflow_Depth := Suppress_Overflow_Depth - 1;
   end Pop_Suppress_Overflow;

   ----------
   -- Emit --
   ----------

   procedure Emit (N : Node_Id) is
   begin
      --  If we're at library level and this node type generates code,
      --  append it to the elab proc.

      if Library_Level
        and then ((Nkind (N) in N_Statement_Other_Than_Procedure_Call
                     and then Nkind (N) /= N_Null_Statement)
                    or else Nkind (N) in N_Subprogram_Call | N_Raise_xxx_Error
                    or else Nkind (N) = N_Raise_Statement
                    or else (Nkind (N) = N_Handled_Sequence_Of_Statements
                               and then Has_Non_Null_Statements
                                          (Statements (N))))
      then
         Add_To_Elab_Proc (N);
         return;

      --  If not at library level and in dead code, start a new basic block
      --  for any code we emit.

      elsif not Library_Level and then Are_In_Dead_Code then
         Position_Builder_At_End (Create_Basic_Block ("dead.code"));
      end if;

      --  If we're in the elaboration procedure, check if we're violating a
      --  No_Elaboration_Code restriction by having a statement there.
      --  Don't check for a possible No_Elaboration_Code restriction
      --  violation on N_Handled_Sequence_Of_Statements, as we want to
      --  signal an error on every nested real statement instead.  This
      --  also avoids triggering spurious errors on dummy (empty) sequences
      --  created by the front-end for package bodies in some cases.

      if (In_Elab_Proc or else In_Elab_Proc_Stmts)
        and then Nkind (N) not in N_Handled_Sequence_Of_Statements |
                                  N_Implicit_Label_Declaration
      then
         Check_Elaboration_Code_Allowed (N);
      end if;

      Set_Debug_Pos_At_Node (N);
      Clear_LValue_List;

      case Nkind (N) is
         when N_Compilation_Unit =>
            declare
               U         : constant Node_Id := Unit (N);
               Subp      : Entity_Id;
               Subp_Body : Node_Id;

            begin
               --  We assume there won't be any elaboration code and
               --  clear that flag if we're wrong.

               Set_Has_No_Elaboration_Code (N, True);

               --  For a body, first process the spec if there is one

               if (Nkind (U) = N_Subprogram_Body and then not Acts_As_Spec (U))
                 or else Nkind (U) = N_Package_Body
               then
                  Emit (Library_Unit (N));
               end if;

               Emit (Context_Items (N));
               Emit_Decl_Lists (Declarations (Aux_Decls_Node (N)));
               Emit (U);

               --  Generate code for all the inlined subprograms

               Subp := First_Inlined_Subprogram (N);
               while Present (Subp) loop
                  Subp_Body := Parent (Declaration_Node (Subp));

                  --  Without optimization or if inlining is disabled,
                  --  process only the required subprograms.

                  if (Has_Pragma_Inline_Always (Subp)
                        or else (not No_Inlining and then Code_Opt_Level > 0))

                    --  The set of inlined subprograms is computed from
                    --  data recorded early during expansion and it can be
                    --  a strict superset of the final set computed after
                    --  semantic analysis, for example if a call to such a
                    --  subprogram occurs in a pragma Assert and assertions
                    --  are disabled.  In that case, semantic analysis
                    --  resets Is_Public to false but the entry for the
                    --  subprogram in the inlining tables is stalled.

                    and then Is_Public (Subp)
                  then
                     if Nkind (Subp_Body) = N_Subprogram_Declaration
                       and then Present (Corresponding_Body (Subp_Body))
                     then
                        Subp_Body := Parent (Declaration_Node
                                               (Corresponding_Body
                                                  (Subp_Body)));
                     end if;

                     if Nkind (Subp_Body) = N_Subprogram_Body then
                        Emit_Subprogram_Body (Subp_Body, For_Inline => True);
                     end if;
                  end if;

                  Next_Inlined_Subprogram (Subp);
               end loop;

               Emit (Actions (Aux_Decls_Node (N)));
               Emit (Pragmas_After (Aux_Decls_Node (N)));
            end;

         when N_Subunit =>
            Emit (Proper_Body (N));

         when N_Package_Declaration =>
            Push_Lexical_Debug_Scope (N);
            Emit (Specification (N));
            Pop_Debug_Scope;

         when N_Package_Specification =>
            Push_Lexical_Debug_Scope (N);
            Emit_Decl_Lists (Visible_Declarations (N),
                             Private_Declarations (N));
            Pop_Debug_Scope;

            if Nkind (Parent (Parent (N))) = N_Compilation_Unit
              and then No (Corresponding_Body (Parent (N)))
            then
               Emit_Elab_Proc (N, Empty, Parent (Parent (N)), False);
            end if;

         when N_Package_Body =>

            --  Skip generic packages

            if Ekind (Unique_Defining_Entity (N)) in Generic_Unit_Kind then
               return;
            end if;

            declare
               Stmts : constant Node_Id := Handled_Statement_Sequence (N);

            begin
               --  If this is the uppermost compilation unit, show any
               --  elaborations are now for the body

               if Nkind (Parent (N)) = N_Compilation_Unit then
                  Mark_Body_Elab;
               end if;

               --  Always process declarations, but they do not provide
               --  a scope, since those declarations are part of what
               --  encloses us, if anything.

               Emit_Decl_Lists (Declarations (N));

               --  If we're at library level and our parent is an
               --  N_Compilation_Unit, make an elab proc and put the
               --  statements there.  Otherwise, emit them, which may add
               --  them to the elaboration table (if we're not at library
               --  level).

               Push_Lexical_Debug_Scope (N);
               if Nkind (Parent (N)) = N_Compilation_Unit then
                  if Present (Corresponding_Spec (N)) then
                     declare
                        Spec : constant Entity_Id := Corresponding_Spec (N);
                        Decl : constant Node_Id   := Declaration_Node (Spec);

                     begin
                        Emit_Elab_Proc (Decl, Empty, Parent (Parent (Decl)));
                     end;
                  end if;

                  Emit_Elab_Proc (N, Stmts, Parent (N), For_Body => True);
               elsif Present (Stmts) then
                  if not Library_Level then
                     Push_Block;
                  end if;

                  Emit (Stmts);
                  if not Library_Level then
                     Pop_Block;
                  end if;
               end if;

               Pop_Debug_Scope;
            end;

         when N_Subprogram_Body =>

            --  Skip generic subprograms

            if not Present (Corresponding_Spec (N))
              or else not (Ekind (Corresponding_Spec (N))
                         in Generic_Subprogram_Kind)
            then
               Emit_Subprogram_Body (N);
            end if;

         when N_Subprogram_Declaration =>

            --  Do not process functions that return arrays because they have
            --  been rewritten as procedures.

            if Ekind (Unique_Defining_Entity (N)) /= E_Function
              or else not Rewritten_For_C (Unique_Defining_Entity (N))
            then
               Emit (Specification (N));
            end if;

         when N_Function_Specification | N_Procedure_Specification =>

            --  Ignore intrinsic subprograms as calls to those will be
            --  expanded.  Also ignore eliminated subprograms.

            if not Is_Intrinsic_Subprogram (Unique_Defining_Entity (N))
              and then not Is_Eliminated (Unique_Defining_Entity (N))
            then
               Discard (Emit_Subprogram_Decl (N, Frozen => False));
            end if;

         when N_Free_Statement =>
            Heap_Deallocate
              (Emit_Expression (Expression (N)),
               (if   Present (Actual_Designated_Subtype (N))
                then Default_GL_Type (Get_Fullest_View
                                        (Actual_Designated_Subtype (N)))
                else No_GL_Type),
               Procedure_To_Call (N), Storage_Pool (N));

         when N_Code_Statement =>
            Emit_Code_Statement (N);

         when N_Handled_Sequence_Of_Statements =>

            --  If this block doesn't contain any statements, ignore it

            if not Has_Non_Null_Statements (Statements (N)) then
               return;
            end if;

            --  If First_Real_Statement is Present, items in Statements
            --  prior to it are declarations and need to be mostly treated
            --  as such except that they are protected by the exception
            --  handlers of this block.  Otherwise, all are statements.

            Start_Block_Statements (At_End_Proc (N), Exception_Handlers (N));
            if Present (First_Real_Statement (N)) then
               Emit_Decl_Lists (Statements (N),
                                End_List => First_Real_Statement (N));
            end if;

            Emit (Statements (N), Starting_At => First_Real_Statement (N));

         when N_Raise_Statement =>
            pragma Assert (Decls_Only or else Back_End_Exceptions);
            Emit_Reraise;

         when N_Raise_xxx_Error =>
            Emit_Raise (N);

         when N_Object_Declaration | N_Exception_Declaration =>
            Emit_Declaration (N);

         when N_Object_Renaming_Declaration
            | N_Exception_Renaming_Declaration =>

            Emit_Renaming_Declaration (N);

         when N_Subprogram_Renaming_Declaration =>

            --  Nothing is needed except for debugging information.
            --  ??? Skip it for now.  Note that in any case, we should
            --  skip Intrinsic subprograms

            null;

         when N_Implicit_Label_Declaration =>

            --  Don't do anything here in case this label isn't actually
            --  used in an N_Label or N_Goto_Statement operation.  If it
            --  were unused, the basic block we create here would be empty,
            --  which LLVM doesn't allow.  This can't occur for
            --  user-defined labels, but can occur with some labels placed
            --  by the front end.  Instead, lazily create the basic block
            --  where it's placed or when its the target of a goto.

            null;

         when N_Assignment_Statement =>
            declare
               LHS  : GL_Value;
               Idxs : Access_GL_Value_Array;
               F    : Entity_Id;

            begin
               --  Get the LHS to evaluate and see if we need to do a
               --  field or array operation.

               LHS_And_Component_For_Assignment (Name (N), LHS, F, Idxs,
                                                 For_LHS => True);

               --  If this is a reference, set atomic or volatile as neeed

               if Present (F) or else Idxs /= null then
                  Mark_Volatile (LHS,
                                 Atomic_Sync_Required (Name (N))
                                   or else Is_Volatile_Reference (Name (N)));
                  Mark_Atomic   (LHS, Atomic_Sync_Required (Name (N)));
               end if;

               --  Now do the operation

               if Present (F) then
                  Build_Field_Store (LHS, F, Emit_Expression (Expression (N)),
                                     VFA => Is_VFA_Ref (Name (N)));
               elsif Idxs /= null then
                  Build_Indexed_Store (LHS, Idxs.all,
                                       Emit_Expression (Expression (N)),
                                       VFA => Is_VFA_Ref (Name (N)));
                  Free (Idxs);

               else
                  Emit_Assignment (LHS,
                                   Expr         => Expression (N),
                                   Forwards_OK  => Forwards_OK (N),
                                   Backwards_OK => Backwards_OK (N),
                                   VFA          => Has_Full_Access (Name (N)));
               end if;
            end;

            --  Deal with any writebacks needed if we had a bitfield in an
            --  LHS context above.

            Perform_Writebacks;

         when N_Procedure_Call_Statement =>

            --  If we're only elaborating decls, we may have a call to a
            --  function whose Name is an N_Selected_Component.  This is
            --  an unexpanded tasking-related call.  Skip it and hope there
            --  are no types only in that call.

            if not Decls_Only or else Nkind (Name (N)) /= N_Selected_Component
            then
               Discard (Emit_Call (N));
            end if;

         when N_Null_Statement =>
            null;

         when N_Label =>
            Discard (Enter_Block_With_Node (N));

         when N_Goto_Statement =>
            Build_Br (Get_Label_BB (Entity (Name (N))));

         when N_Exit_Statement =>
            declare
               Exit_BB : constant Basic_Block_T := Get_Exit_Point (Name (N));
               Next_BB : Basic_Block_T;
            begin
               if Present (Condition (N)) then
                  Next_BB := Create_Basic_Block ("loop.after.exit");
                  Emit_If_Cond (Condition (N), Exit_BB, Next_BB);
                  Position_Builder_At_End (Next_BB);
               else
                  Build_Br (Exit_BB);
               end if;
            end;

         when N_Simple_Return_Statement =>
            Emit_Return_Statement (N);

         when N_If_Statement =>
            Emit_If (N);

         when N_Loop_Statement =>
            Emit_Loop_Statement (N);

         when N_Block_Statement =>
            Push_Lexical_Debug_Scope (N);
            Push_Block;
            Emit_Decl_Lists (Declarations (N));
            Emit (Handled_Statement_Sequence (N));
            Set_Debug_Pos_At_Node (N);
            Pop_Block;
            Pop_Debug_Scope;

         when N_Incomplete_Type_Declaration
            | N_Private_Extension_Declaration
            | N_Private_Type_Declaration =>

            --  Ignore incomplete type declarations since we'll either
            --  elaborate the type when we see the full declaration or
            --  lazily elaborate the it either when we need it.

            null;

         when N_Full_Type_Declaration
            | N_Subtype_Declaration
            | N_Task_Type_Declaration
           =>
            declare
               TE : constant Entity_Id :=
                 Get_Fullest_View (Defining_Identifier (N));

            begin
               Discard (Type_Of (TE));

               --  Now copy any back-annotations from what we
               --  elaborated to this type.

               Copy_Annotations (TE, Defining_Identifier (N));
            end;

         when N_Freeze_Entity =>
            Process_Freeze_Entity (N);
            Emit_Decl_Lists (Actions (N));

         when N_Pragma =>
            Emit_Pragma (N);

         when N_Case_Statement =>
            Emit_Case_Statement (N);

         when N_Body_Stub =>

            --  If we have a "separate" (either subprogram or package), we
            --  compile that as part of this unit, so go into it.

            if Present (Library_Unit (N)) then
               Emit (Unit (Library_Unit (N)));
            end if;

         --  Nodes we actually want to ignore, in many cases because they
         --  represent things that are put elsewhere in the tree (e.g,
         --  rep clauses).

         when N_Abstract_Subprogram_Declaration
            | N_At_Clause
            | N_Call_Marker
            | N_Empty
            | N_Enumeration_Representation_Clause
            | N_Enumeration_Type_Definition
            | N_Function_Instantiation
            | N_Freeze_Generic_Entity
            | N_Generic_Function_Renaming_Declaration
            | N_Generic_Package_Renaming_Declaration
            | N_Generic_Procedure_Renaming_Declaration
            | N_Generic_Package_Declaration
            | N_Generic_Subprogram_Declaration
            | N_Itype_Reference
            | N_Number_Declaration
            | N_Package_Instantiation
            | N_Package_Renaming_Declaration
            | N_Procedure_Instantiation
            | N_Protected_Type_Declaration
            | N_Record_Representation_Clause
            | N_Validate_Unchecked_Conversion
            | N_Variable_Reference_Marker
            | N_Use_Package_Clause
            | N_Use_Type_Clause
            | N_With_Clause
           =>
            null;

         when N_Push_Constraint_Error_Label .. N_Pop_Storage_Error_Label =>
            Process_Push_Pop_xxx_Error_Label (N);

         when N_Attribute_Definition_Clause =>

            --  The only interesting case left after expansion is for Address
            --  clauses. We only deal with 'Address if the object has a Freeze
            --  node.

            if Get_Attribute_Id (Chars (N)) = Attribute_Address
              and then Present (Freeze_Node (Entity (Name (N))))
            then
               declare
                  Expr : constant Node_Id := Expression (N);

               begin
                  if Library_Level and then not Is_Static_Address (Expr) then
                     Add_To_Elab_Proc (Expr, For_GT => Full_GL_Type (Expr));
                  else
                     Set_Value (Expr, Emit_Expression (Expr));
                  end if;
               end;
            end if;

         when others =>
            pragma Assert (Decls_Only);
      end case;
   end Emit;

   --------------------
   -- Emit_Safe_Expr --
   --------------------

   function Emit_Safe_Expr
     (N : Node_Id; LHS : GL_Value := No_GL_Value) return GL_Value is
   begin
      return V : GL_Value do
         Push_LValue_List;
         Push_Debug_Freeze_Pos;
         V := Emit_Expression (N, LHS => LHS);
         Pop_Debug_Freeze_Pos;
         Pop_LValue_List;
      end return;
   end Emit_Safe_Expr;

   -----------------
   -- Emit_LValue --
   -----------------

   function Emit_LValue
     (N          : Node_Id;
      LHS        : GL_Value := No_GL_Value;
      For_LHS    : Boolean  := False) return GL_Value is
   begin
      --  We have an important special case here.  If N is an N_Identifier or
      --  N_Expanded_Name and its value is a Reference, always return that
      --  reference in preference to returning its value and forcing it into
      --  memory.  But don't do this for subprograms since they may need
      --  static links and avoid variables that are in activation records.

      if Nkind (N) in N_Identifier | N_Expanded_Name
        and then Ekind (Entity (N)) not in E_Function | E_Procedure
        and then No (Get_From_Activation_Record (Entity (N)))
        and then Present (Get_Value (Entity (N)))
        and then Is_Single_Reference (Get_Value (Entity (N)))
      then
         return Get_Value (Entity (N));
      else
         return Get (Emit (N, LHS, For_LHS => For_LHS, Prefer_LHS => True),
                     Any_Reference);
      end if;
   end Emit_LValue;

   ----------------------
   -- Emit_Safe_LValue --
   ----------------------

   function Emit_Safe_LValue
     (N          : Node_Id;
      LHS        : GL_Value := No_GL_Value;
      For_LHS    : Boolean  := False) return GL_Value is
   begin
      return V : GL_Value do
         Push_LValue_List;
         Push_Debug_Freeze_Pos;
         V := Emit_LValue (N, LHS => LHS, For_LHS => For_LHS);
         Pop_Debug_Freeze_Pos;
         Pop_LValue_List;
      end return;
   end Emit_Safe_LValue;

   ----------
   -- Emit --
   ----------

   function Emit
     (N          : Node_Id;
      LHS        : GL_Value := No_GL_Value;
      For_LHS    : Boolean  := False;
      Prefer_LHS : Boolean  := False) return GL_Value
   is
      Is_Volatile : constant Boolean :=
        (Nkind (N) /= N_Defining_Identifier
           and then Is_Volatile_Reference (N));
      Is_Atomic   : constant Boolean :=
        Is_Atomic_Object (N)
        or else (Nkind (N) in N_Expanded_Name | N_Explicit_Dereference |
                              N_Identifier    | N_Indexed_Component    |
                              N_Selected_Component
                   and then Atomic_Sync_Required (N));
      Result      : GL_Value         :=
        Emit_Internal (N, LHS, For_LHS => For_LHS, Prefer_LHS => Prefer_LHS);

   begin
      --  If we have an overflow, convert it to an undef.  Unless we're to
      --  suppress the error, also give an error and emit a raise.

      if Overflowed (Result) then
         Result := Get_Undef_Relationship (Related_Type (Result),
                                           Relationship (Result));
         if Suppress_Overflow_Depth = 0 then
            Error_Msg_N ("??`Constraint_Error` will be raised at run time",
                         N);
            Emit_Raise_Call (N, CE_Overflow_Check_Failed);
         end if;
      end if;

      --  Now mark the result as volatile or atomic as needed, maybe add
      --  it to the LValue list, and return it.

      Mark_Volatile (Result, Is_Volatile or else Is_Atomic);
      Mark_Atomic   (Result, Is_Atomic);
      return Add_To_LValue_List (Result);
   end Emit;

   -------------------------
   -- Simple_Value_Action --
   -------------------------

   function Simple_Value_Action
     (N : Node_Id; Has_All : out Boolean) return Node_Id
   is
      Action : Node_Id := First (Actions (N));
      Expr   : Node_Id := Expression (N);
      Freeze : Node_Id := First (Actions (N));

   begin
      --  Skip any non-executable nodes

      while Nkind (Action) in N_Call_Marker | N_Null_Statement |
                              N_Full_Type_Declaration | N_Subtype_Declaration
        or else (Nkind (Action) = N_Freeze_Entity
                   and then No (Actions (Action)))
      loop
         Next (Action);
      end loop;

      --  If the expression of this node is an N_Explicit_Dereference, note
      --  it and get the inner expression.

      Has_All := Nkind (Expr) = N_Explicit_Dereference;
      if Has_All then
         Expr := Prefix (Expr);
      end if;

      --  If the next action isn't the last or isn't a declaration of the
      --  identifier in Expression, this is not a case we handle.

      if Nkind (Action) /= N_Object_Declaration
        or else Present (Next (Action))
        or else Nkind (Expr) /= N_Identifier
        or else Defining_Identifier (Action) /= Entity (Expr)
      then
         return Empty;
      end if;

      --  Process any freeze nodes we may have skipped

      while Present (Freeze) loop
         if Nkind (Freeze) = N_Freeze_Entity then
            Process_Freeze_Entity (Freeze);
         end if;

         Next (Freeze);
      end loop;

      --  If we have an N_Explicit_Dereference and Action's expression is
      --  an N_Reference, use the inner expression.

      return Init : Node_Id := Expression (Action) do
         if  Has_All and then Nkind (Init) = N_Reference then
            Has_All := False;
            Init    := Prefix (Init);
         end if;
      end return;

   end Simple_Value_Action;

   --------------------
   --  Emit_Internal --
   --------------------

   function Emit_Internal
     (N          : Node_Id;
      LHS        : GL_Value := No_GL_Value;
      For_LHS    : Boolean  := False;
      Prefer_LHS : Boolean  := False) return GL_Value
   is
      GT     : constant GL_Type := Full_GL_Type (N);
      Expr   : Node_Id;
      Result : GL_Value;

   begin
      Set_Debug_Pos_At_Node (N);

      case Nkind (N) is
         when N_Binary_Op =>
            pragma Assert (not For_LHS);

            if Nkind (N) in N_Op_Compare then
               return Emit_Comparison (Nkind (N), Left_Opnd (N),
                                       Right_Opnd (N));
            elsif Nkind (N) in N_Op_Shift then
               return Emit_Shift (Nkind (N), Left_Opnd (N), Right_Opnd (N));
            elsif Nkind (N) in N_Op_And | N_Op_Or | N_Op_Xor
              and then Is_Boolean_Type (GT)
            then
               return
                 Emit_And_Or_Xor (Nkind (N), Left_Opnd (N), Right_Opnd (N));
            else
               return Emit_Binary_Operation (N);
            end if;

         when N_Unary_Op =>
            pragma Assert (not For_LHS);

            --  Check for the special case of taking the NOT of a comparison,
            --  in which case we can just emit a different comparison.

            if Nkind (N) = N_Op_Not
              and then Nkind (Right_Opnd (N)) in N_Op_Compare
            then
               return Emit_Comparison ((case Nkind (Right_Opnd (N)) is
                                          when N_Op_Eq => N_Op_Ne,
                                          when N_Op_Ne => N_Op_Eq,
                                          when N_Op_Lt => N_Op_Ge,
                                          when N_Op_Le => N_Op_Gt,
                                          when N_Op_Gt => N_Op_Le,
                                          when N_Op_Ge => N_Op_Lt,
                                          when others  => N_Op_Not),
                                        Left_Opnd  (Right_Opnd (N)),
                                        Right_Opnd (Right_Opnd (N)));
            else
               return Emit_Unary_Operation (N);
            end if;

         when N_Expression_With_Actions =>

            declare
               Has_All : Boolean;
               Expr    : constant Node_Id  := Simple_Value_Action (N, Has_All);

            begin
               --  If this is just defining the value that is to be its result,
               --  just expand the initializer.

               if Present (Expr) then
                  Result := Emit (Expr,
                                  LHS        => LHS,
                                  For_LHS    => For_LHS,
                                  Prefer_LHS => Prefer_LHS);
                  if Has_All then
                     Result := From_Access (Result);
                  end if;

                  return Result;
               end if;

               --  Otherwise do each action and evaluate our expression

               Push_LValue_List;
               Emit (Actions (N));
               Pop_LValue_List;
               return Emit (Expression (N),
                            LHS        => LHS,
                            For_LHS    => For_LHS,
                            Prefer_LHS => Prefer_LHS);
            end;

         when N_Character_Literal | N_Numeric_Or_String_Literal =>
            pragma Assert (not For_LHS);

            return Emit_Literal (N);

         when N_And_Then | N_Or_Else =>
            pragma Assert (not For_LHS);

            if Safe_For_Short_Circuit (Left_Opnd (N))
              and then Safe_For_Short_Circuit (Right_Opnd (N))
              and then Is_Simple_Conditional (N)
            then
               return Emit_And_Or_Xor ((if   Nkind (N) = N_And_Then
                                        then N_Op_And else N_Op_Or),
                                       Left_Opnd (N), Right_Opnd (N));
            else
               return Build_Short_Circuit_Op (Left_Opnd (N), Right_Opnd (N),
                                              Nkind (N));
            end if;

         when N_Unchecked_Type_Conversion =>
            declare
               Expr   : constant Node_Id   := Expression (N);
               BT     : constant Entity_Id := Full_Base_Type (GT);

            begin
               --  The result can't have overflowed (this is unchecked),
               --  but if this is not just converting between subtypes of
               --  the same base type, it must be marked as aliasing
               --  everything.

               Result := Emit_Conversion (Expr, GT, N,
                                          Is_Unchecked  => True,
                                          No_Truncation => No_Truncation (N));
               Clear_Overflowed (Result);
               if Full_Base_Type (Full_Etype (Expr)) /= BT then
                  Set_Aliases_All (Result);
               end if;

               return Result;
            end;

         when N_Type_Conversion =>
            return Emit_Conversion
              (Expression (N), GT, N,
               Need_Overflow_Check => Do_Overflow_Check (N),
               Float_Truncate      => Float_Truncate (N));

         when N_Qualified_Expression =>
            return Emit_Conversion (Expression (N), GT, N);

         when N_Identifier
            | N_Expanded_Name
            | N_Operator_Symbol
            | N_Defining_Identifier
            | N_Defining_Operator_Symbol
            =>
            return Emit_Identifier (N, Prefer_LHS => Prefer_LHS);

         when N_Function_Call =>

            --  If we're only elaborating decls, we may have a call to a
            --  function whose Name is an N_Selected_Component.  This is
            --  an unexpanded tasking-related call.  Skip it and hope there
            --  are no types only in that call.

            if Decls_Only and then Nkind (Name (N)) = N_Selected_Component then
               return Emit_Undef (GT);
            else
               pragma Assert (Decls_Only or else not For_LHS);
               return Emit_Call (N, LHS => LHS);
            end if;

         when N_Explicit_Dereference =>

            --  If we have a .all of a 'Reference, we can just evaluate
            --  the inner expression. This allows us to pass our LHS info.

            if Nkind (Prefix (N)) = N_Reference then
               return Emit (Prefix (Prefix (N)),
                            LHS        => LHS,
                            For_LHS    => For_LHS,
                            Prefer_LHS => Prefer_LHS);
            else
               --  Get a reference to our prefix

               Result := From_Access (Emit_Expression (Prefix (N)));
            end if;

            --  If we have a reference to a global constant, we can
            --  use the value instead.

            if Is_Reference (Result) and then Is_A_Global_Variable (Result)
              and then Is_Global_Constant (Result)
            then
               Result := Get_Initializer (Result);
            end if;

            --  Finally see if we have an Actual_Designated_Subtype that we
            --  have to convert to.

            if Present (Actual_Designated_Subtype (N)) then
               Result := Convert_Ref (Get (Result, Reference),
                                      Default_GL_Type
                                        (Get_Fullest_View
                                           (Actual_Designated_Subtype (N))));
            end if;

            return Result;

         when N_Allocator =>
            declare
               Expr  : constant Node_Id := Expression (N);
               Value : GL_Value         := No_GL_Value;
               A_GT  : GL_Type;

            begin
               --  There are two cases: the Expression operand can
               --  either be an N_Identifier or Expanded_Name, which
               --  must represent a type, or a N_Qualified_Expression,
               --  which contains both the object type and an initial
               --  value for the object.

               pragma Assert (not For_LHS);

               if Decls_Only then
                  return Get_Undef (GT);
               elsif Is_Entity_Name (Expr) then
                  A_GT  := Default_GL_Type (Get_Fullest_View (Entity (Expr)));
                  Value := No_GL_Value;
               else
                  pragma Assert (Nkind (Expr) = N_Qualified_Expression);
                  A_GT  := Full_GL_Type (Expression (Expr));
                  Value := Emit_Expression (Expression (Expr));
               end if;

               --  If GT's designated type is a record with discriminants
               --  and there's no Value, we're usually passed a subtype as
               --  A_GT.  But in some cases (such as where it's limited), we
               --  aren't.

               Result := Heap_Allocate_For_Type
                 (Full_Designated_GL_Type (GT), A_GT,
                  V        => Value,
                  N        => N,
                  Proc     => Procedure_To_Call (N),
                  Pool     => Storage_Pool (N),
                  Max_Size => (Is_Unconstrained_Record (A_GT)
                                 and then No (Value)));
               return Convert_To_Access (Result, GT);
            end;

         when N_Reference =>

            --  If we have a 'Reference of a .all, we can just evaluate
            --  the inner expression. This allows us to pass our LHS info.

            if Nkind (Prefix (N)) = N_Explicit_Dereference then
               return Emit (Prefix (Prefix (N)),
                            LHS        => LHS,
                            For_LHS    => For_LHS,
                            Prefer_LHS => Prefer_LHS);
            else
               --  It's tempting to mark the call below as For_LHS, but we
               --  do allow taking 'Reference of something that's not an
               --  LValue (though an assignment to it will fail in that
               --  case).

               return Convert_To_Access (Emit_LValue (Prefix (N)), GT);
            end if;

         when N_Attribute_Reference =>
            return Emit_Attribute_Reference (N);

         when N_Selected_Component =>

            --  If we're just processing declarations, make sure we've
            --  elaborated the type of the prefix and do nothing more.

            if Decls_Only then
               Discard (Full_GL_Type (Prefix (N)));
               return Emit_Undef (GT);
            else
               return Maybe_Convert_GT
                 (Build_Field_Load (Emit (Prefix (N),
                                          For_LHS    => For_LHS,
                                          Prefer_LHS => Prefer_LHS),
                                    Entity (Selector_Name (N)),
                                    LHS        => LHS,
                                    For_LHS    => For_LHS,
                                    Prefer_LHS => Prefer_LHS,
                                    VFA        =>
                                      Has_Full_Access (Prefix (N))),
                  GT);
            end if;

         when N_Indexed_Component | N_Slice =>
            Result := Emit (Prefix (N),
                            For_LHS    => For_LHS,
                            Prefer_LHS => Prefer_LHS);

            --  If we're just processing decls, the above is all we have to do

            if Decls_Only then
               return Emit_Undef (GT);

            --  This can be an integer type if it's the implementation
            --  type of a packed array type.  In that case, convert it to
            --  the result type.

            elsif Is_Integer_Type (Related_Type (Result))
              and then Is_Packed_Array_Impl_Type (Related_Type (Result))
            then
               --  Evaluate any expressions in case they have side-effects

               Expr := First (Expressions (N));
               while Present (Expr) loop
                  if not Is_No_Elab_Needed (Expr) then
                     Discard (Emit (Expr));
                  end if;

                  Next (Expr);
               end loop;

               return (if   Is_Reference (Result) then Convert_Ref (Result, GT)
                       else Convert (Result, GT));

            elsif Nkind (N) = N_Indexed_Component then
               return Maybe_Convert_GT
                 (Build_Indexed_Load (Result,
                                      Get_Indices (Expressions (N), Result),
                                      For_LHS    => For_LHS,
                                      Prefer_LHS => Prefer_LHS,
                                      VFA        =>
                                        Has_Full_Access (Prefix (N))),
                  GT);

            else
               return Get_Slice_LValue (GT, Get (Result, Any_Reference));
            end if;

         when N_Aggregate | N_Extension_Aggregate =>
            pragma Assert (not For_LHS);

            if Null_Record_Present (N) and then not Is_Nonnative_Type (GT) then
               return Const_Null (GT);

            elsif Ekind (GT) in Record_Kind then
               return Emit_Record_Aggregate
                 (N, (if   Present (LHS) and then Is_Safe_From (LHS, N)
                      then LHS else No_GL_Value));

            elsif not Is_Array_Type (GT) then
               pragma Assert (Decls_Only);
               return Emit_Undef (GT);
            else
               --  The back-end supports exactly two types of array
               --  aggregates.  One is for a fixed-size aggregate.  The
               --  other are very special cases of Others that are tested
               --  for in Aggr_Assignment_OK_For_Backend in Exp_Aggr.

               return Emit_Array_Aggregate
                 (N, Number_Dimensions (GT), (1 .. 0 => <>),
                  (if   Present (LHS) and then Is_Safe_From (LHS, N) then LHS
                   else No_GL_Value));
            end if;

         when N_If_Expression =>
            pragma Assert (not For_LHS);

            return Emit_If_Expression (N, LHS => LHS);

         when N_Null =>
            pragma Assert (not For_LHS);

            return Const_Null (GT);

         when N_In =>
            declare
               Left       : constant GL_Value :=
                 Emit_Expression (Left_Opnd (N));
               Rng        : Node_Id           := Right_Opnd (N);
               Compare_LB : GL_Value;
               Compare_HB : GL_Value;

            begin
               if Decls_Only then
                  return Get (Get_Undef (Boolean_GL_Type), Boolean_Data);
               end if;

               pragma Assert (not For_LHS);
               pragma Assert (No (Alternatives (N)));

               if Nkind (Rng) = N_Identifier then
                  Rng := Scalar_Range (Full_Etype (Rng));
               end if;

               Compare_LB := Build_Elementary_Comparison
                 (N_Op_Ge, Left, Emit_Expression (Low_Bound (Rng)));
               Compare_HB := Build_Elementary_Comparison
                 (N_Op_Le, Left, Emit_Expression (High_Bound (Rng)));
               return Build_And (Compare_LB, Compare_HB);
            end;

         when N_Raise_xxx_Error =>
            pragma Assert (No (Condition (N)));

            Emit_Raise (N);
            return Emit_Undef (GT);

         when others =>
            pragma Assert (Decls_Only);

            return Emit_Undef (GT);
      end case;
   end Emit_Internal;

   ----------
   -- Emit --
   ----------

   procedure Emit (List : List_Id; Starting_At : Node_Id := Empty) is
      N : Node_Id;
   begin
      if Present (List) then
         N := (if Present (Starting_At) then Starting_At else First (List));

         while Present (N) loop

            --  If N is an N_Handled_Sequence_Of_Statements here, we know
            --  that it's not nested in a block.  It probably was from a
            --  package body at library level and ended in the elab proc.
            --  Make a block around it.

            if Nkind (N) = N_Handled_Sequence_Of_Statements then
               Push_Block;
               Emit (N);
               Pop_Block;

            else
               Emit (N);
            end if;

            Next (N);
         end loop;
      end if;
   end Emit;

   --  Freeze nodes for package bodies are relatively rare, so we can store
   --  information about them in a table that we search for the relevant
   --  entity.  We need to handle the case where we're at library level
   --  (so what we have to save is the position into the elab table) or
   --  in code, where we need to save a pointer to a branch we add to a new
   --  basic block that we made.  Note that in the latter case, we can't
   --  use Get_Current_Position / Set_Current_Position because those are
   --  intended for adding individual instructions within a basic block
   --  but here we need to insert large amounts of code, including basic
   --  blocks.

   type Code_Position (Library : Boolean := False) is record
      E : Entity_Id;
      case Library is
         when True =>
            Elab_Ptr : Nat;

         when False =>
            Branch_Inst : Value_T;
      end case;
   end record;

   package Code_Positions is new Table.Table
     (Table_Component_Type => Code_Position,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 5,
      Table_Name           => "Code_Positions");

   --------------------------
   -- Record_Code_Position --
   --------------------------

   procedure Record_Code_Position (E : Entity_Id) is
   begin
      if Library_Level then

         --  Add a dummy entry into the elab list so that multiple
         --  consecutive calls will have different positions and record our
         --  position in the list.

         Add_To_Elab_Proc (Empty);
         Code_Positions.Append ((True, E, Get_Elab_Position));

      else
         --  Create a new basic block and branch to it.  Later, we'll
         --  replace the branch we made to a branch to our new code and then
         --  branch to that new block.

         declare
            BB : constant Basic_Block_T := Create_Basic_Block;

         begin
            Code_Positions.Append ((False, E, Build_Br (IR_Builder, BB)));
            Position_Builder_At_End (BB);
         end;
      end if;

   end Record_Code_Position;

   ---------------------
   -- Insert_Code_For --
   ---------------------

   procedure Insert_Code_For (E : Entity_Id) is
      Code_To_Emit : constant Node_Id :=
        Parent (Corresponding_Body (Parent (Declaration_Node (E))));

   begin
      for J in 1 .. Code_Positions.Last loop
         declare
            RCP  : constant Code_Position := Code_Positions.Table (J);
         begin
            if RCP.E = E then
               pragma Assert (Library_Level = RCP.Library);

               if RCP.Library then

                  --  Get the elab pointer that we saved and the first one
                  --  that we'll generate.

                  declare
                     Prev_Ptr  : constant Nat := RCP.Elab_Ptr;
                     Start_Ptr : constant Nat := Get_Elab_Position;
                     Last_Ptr  : Nat;

                  begin
                     --  Then emit our code and reorder the elab entries

                     Emit (Code_To_Emit);
                     Last_Ptr := Get_Elab_Position;
                     Reorder_Elab_Table (Prev_Ptr, Start_Ptr);

                     --  Now look for other pointers that have been stored
                     --  in the code position table and are behind us and
                     --  update them to account for our length.

                     for K in 1 .. Code_Positions.Last loop
                        declare
                           RCP2 : Code_Position
                             renames Code_Positions.Table (K);

                        begin
                           if RCP2.Library and then RCP2.Elab_Ptr > Prev_Ptr
                           then
                              RCP2.Elab_Ptr
                                := RCP2.Elab_Ptr + Last_Ptr - Start_Ptr;
                           end if;
                        end;
                     end loop;
                  end;
               else
                  --  Make a new block and and get pointers to all the
                  --  relevant blocks.  Then rewrite the branch to point
                  --  to our code, emit our code, and branch to the new
                  --  block that we used to branch to.

                  declare
                     Our_BB  : constant Basic_Block_T := Get_Insert_Block;
                     New_BB  : constant Basic_Block_T := Create_Basic_Block;
                     Inst    : constant Value_T       := RCP.Branch_Inst;
                     Old_BB  : constant Basic_Block_T :=
                       Get_Instruction_Parent (Inst);
                     Targ_BB : constant Basic_Block_T :=
                       Basic_Block_T (Get_Operand (Inst, 0));

                  begin
                     Instruction_Erase_From_Parent (Inst);
                     Position_Builder_At_End (Old_BB);
                     Move_To_BB (New_BB);
                     Emit (Code_To_Emit);
                     Build_Br (Targ_BB);
                     Position_Builder_At_End (Our_BB);
                  end;
               end if;
            end if;
         end;
      end loop;
   end Insert_Code_For;

   ---------------------------
   -- Process_Freeze_Entity --
   ---------------------------

   procedure Process_Freeze_Entity (N : Node_Id) is
      E    : constant Entity_Id := Entity (N);
      Decl : constant Node_Id   := Declaration_Node (E);
   begin
      case Nkind (Decl) is
         when N_Object_Declaration | N_Exception_Declaration =>

            --  For objects, perform the object declaration

            Emit_Declaration (Decl, For_Freeze_Entity => True);

         when N_Procedure_Specification | N_Function_Specification =>

            --  For subprograms, the decl node points to the subprogram
            --  specification.  We only want to consider "normal"
            --  subprograms that aren't intrinsic, so we not only test for
            --  intrinsic but for an N_Subprogram_Declaration, as opposed
            --  to, for example an N_Abstract_Subprogram_Declaration, which
            --  we don't process. We also have to test for protected
            --  subprograms and finally ignore functions that return arrays
            --  because they have been rewritten as procedures.

            if not Is_Intrinsic_Subprogram (E)
              and then Nkind (Parent (Decl)) = N_Subprogram_Declaration
              and then Convention (E) /= Convention_Protected
              and then No (Protected_Body_Subprogram (E))
              and then not Is_Eliminated (E)
              and then not
                (Ekind (Defining_Unit_Name (Decl)) = E_Function
                  and then Rewritten_For_C (Defining_Unit_Name (Decl)))
            then
               Discard (Emit_Subprogram_Decl (Decl));
            end if;

         when N_Package_Specification =>

            --  Write out the code for this specification at the point of the
            --  initial declaration.

            Insert_Code_For (E);

         when others =>
            null;
      end case;
   end Process_Freeze_Entity;

   -------------------------
   -- Emit_Loop_Statement --
   -------------------------

   procedure Emit_Loop_Statement (N : Node_Id) is
      Loop_Identifier : constant Entity_Id :=
        (if Present (Identifier (N)) then Entity (Identifier (N)) else Empty);
      Iter_Scheme     : constant Node_Id   := Iteration_Scheme (N);
      Is_Mere_Loop    : constant Boolean   := No (Iter_Scheme);
      Is_For_Loop     : constant Boolean   :=
        not Is_Mere_Loop
        and then Present (Loop_Parameter_Specification (Iter_Scheme));

      --  The general format for a loop is:
      --    INIT;
      --    while COND loop
      --       STMTS;
      --       ITER;
      --    end loop;
      --    NEXT:
      --
      --  Each step has its own basic block. When a loop doesn't need one
      --  of these steps, just alias it with another one.

      BB_Cond : Basic_Block_T              :=
        (if   not Is_For_Loop then Enter_Block_With_Node (Empty)
         else Create_Basic_Block ("loop.cond"));
      --  If this is not a FOR loop, there is no initialization: alias
      --  it with the COND block.

      BB_Stmts : constant Basic_Block_T    :=
        (if   Is_Mere_Loop or else Is_For_Loop
         then BB_Cond else Create_Basic_Block ("loop.stmts"));
      --  If this is a mere loop or a For loop, there is no condition
      --  block: alias it with the STMTS block.

      BB_Iter : Basic_Block_T              :=
        (if Is_For_Loop then Create_Basic_Block ("loop.iter") else BB_Cond);
      --  If this is not a FOR loop, there is no iteration: alias it with
      --  the COND block, so that at the end of every STMTS, jump on ITER
      --  or COND.

      BB_Next : constant Basic_Block_T     := Create_Basic_Block ("loop.exit");
      --  The NEXT step contains no statement that comes from the loop: it
      --  is the exit point.

   begin
      --  First compile the iterative part of the loop: evaluation of the
      --  exit condition, etc.

      if not Is_Mere_Loop then
         if not Is_For_Loop then

            --  This is a WHILE loop: jump to the loop-body if the
            --  condition evaluates to True, jump to the loop-exit
            --  otherwise.

            if not Decls_Only then
               Position_Builder_At_End (BB_Cond);
               Emit_If_Cond (Condition (Iter_Scheme), BB_Stmts, BB_Next);
            end if;

         else
            --  This is a FOR loop

            declare
               Spec       : constant Node_Id   :=
                 Loop_Parameter_Specification (Iter_Scheme);
               E          : constant Node_Id   := Defining_Identifier (Spec);
               Reversed   : constant Boolean   := Reverse_Present (Spec);
               Var_GT     : constant GL_Type   := Full_GL_Type (E);
               Prim_GT    : constant GL_Type   := Primitive_GL_Type (Var_GT);
               Var_BT     : constant GL_Type   := Base_GL_Type (Var_GT);
               Uns_BT     : constant Boolean   := Is_Unsigned_Type (Var_BT);
               One        : constant GL_Value  := Const_Int (Prim_GT, Uint_1);
               LLVM_Var   : GL_Value;
               Low, High  : GL_Value;
               Prev, Next : GL_Value;

            begin
               --  Initialization block: create the loop variable and
               --  initialize it.

               Bounds_From_Type (Var_GT, Low, High);
               LLVM_Var := Allocate_For_Type
                 (Var_GT,
                  N => E,
                  V => (if Reversed then High else Low),
                  E => E);

               Set_Value (E, LLVM_Var);
               Create_Local_Variable_Debug_Data (E, LLVM_Var);

               --  Then go to the condition block if the range isn't empty.
               --  Note that this comparison must be done in the base type.

               Build_Cond_Br
                 (I_Cmp ((if Uns_BT then Int_ULE else Int_SLE),
                   Convert (Low, Var_BT), Convert (High, Var_BT)),
                   BB_Cond, BB_Next);

               --  Stop if the loop variable was equal to the "exit"
               --  bound. Increment/decrement it otherwise.

               BB_Cond := Create_Basic_Block ("loop.cond.iter");
               Position_Builder_At_End (BB_Cond);
               Prev := To_Primitive (Get (LLVM_Var, Data));
               Build_Cond_Br
                 (I_Cmp (Int_EQ, Prev,
                         To_Primitive ((if Reversed then Low else High))),
                  BB_Next, BB_Iter);

               Position_Builder_At_End (BB_Iter);
               Next :=  (if   Reversed then Sub (Prev, One)
                         else Add (Prev, One));
               Store (From_Primitive (Next, Var_GT), LLVM_Var);
               Build_Br (BB_Stmts);

               --  The ITER step starts at this special COND step

               BB_Iter := BB_Cond;
            end;
         end if;
      end if;

      --  Finally, emit the body of the loop.  Save and restore the stack
      --  around that code, so we free any variables allocated each iteration.

      Position_Builder_At_End (BB_Stmts);
      Push_Loop (Loop_Identifier, BB_Next);
      Push_Block;
      Start_Block_Statements;
      Emit (Statements (N));
      Set_Debug_Pos_At_Node (N);
      Pop_Block;
      Pop_Loop;

      Build_Br (BB_Iter);
      Position_Builder_At_End (BB_Next);
   end Emit_Loop_Statement;

end GNATLLVM.Compile;
