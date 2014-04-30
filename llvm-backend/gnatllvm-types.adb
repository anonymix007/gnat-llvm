with Sem_Eval; use Sem_Eval;
with Sinfo;    use Sinfo;
with Stand;    use Stand;
with Uintp; use Uintp;
with Ttypes;

with GNATLLVM.Compile;

package body GNATLLVM.Types is

   ----------------------
   -- Get_Address_Type --
   ----------------------

   function Get_Address_Type return Type_T
   is
     (Int_Ty (Natural (Ttypes.System_Address_Size)));

   function Create_Subprogram_Type
     (Env           : Environ;
      Params        : Entity_Iterator;
      Return_Type   : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T;
   --  Helper for public Create_Subprogram_Type functions: the public ones
   --  harmonize input and this one actually creates the LLVM type for
   --  subprograms.

   function Create_Subprogram_Access_Type
     (Env       : Environ;
      Subp_Type : Type_T) return Type_T;
   --  Return a structure type that embeds Subp_Type and a static link pointer

   ----------------------------------
   -- Get_Innermost_Component_Type --
   ----------------------------------

   function Get_Innermost_Component_Type
     (Env : Environ; N : Entity_Id) return Type_T
   is
     (if Is_Array_Type (N)
      then Get_Innermost_Component_Type (Env, Component_Type (N))
      else Create_Type (Env, N));

   ------------
   -- Int_Ty --
   ------------

   function Int_Ty (Num_Bits : Natural) return Type_T
   is
      (Int_Type (Interfaces.C.unsigned (Num_Bits)));

   ----------------------------
   -- Register_Builtin_Types --
   ----------------------------

   procedure Register_Builtin_Types (Env : Environ) is

      procedure Set_Rec (E : Entity_Id; T : Type_T);
      procedure Set_Rec (E : Entity_Id; T : Type_T) is
      begin
         Env.Set (E, T);
         if Etype (E) /= E then
            Set_Rec (Etype (E), T);
         end if;
      end Set_Rec;

      use Interfaces.C;
      Int_Size : constant unsigned := unsigned (Get_Int_Size);
   begin
      Set_Rec (Universal_Integer, Int_Type_In_Context (Env.Ctx, Int_Size));
      Set_Rec (Standard_Integer, Int_Type_In_Context (Env.Ctx, Int_Size));
      Set_Rec (Standard_Boolean, Int_Type_In_Context (Env.Ctx, 1));
      Set_Rec (Standard_Natural, Int_Type_In_Context (Env.Ctx, Int_Size));

      --  TODO??? add other builtin types!
   end Register_Builtin_Types;

   -----------
   -- Fn_Ty --
   -----------

   function Fn_Ty (Param_Ty : Type_Array; Ret_Ty : Type_T) return Type_T
   is
     (Function_Type (Ret_Ty, Param_Ty'Address, Param_Ty'Length, False));

   ------------------------------
   -- Create_Array_Bounds_Type --
   ------------------------------

   function Create_Array_Bounds_Type
     (Env             : Environ;
      Array_Type_Node : Entity_Id) return Type_T
   is
      function Iterate is new Iterate_Entities
        (Get_First => First_Index,
         Get_Next  => Next_Index);

      Indices : constant Entity_Iterator := Iterate (Array_Type_Node);
      Fields  : array (1 .. 2 * Indices'Length) of Type_T;
      I       : Natural := 1;
   begin
      for Index of Indices loop
         Fields (I) := Create_Type (Env, Etype (Index));
         Fields (I + 1) := Fields (I);
         I := I + 2;
      end loop;
      return Struct_Type_In_Context
        (Env.Ctx, Fields'Address, Fields'Length, Packed => False);
   end Create_Array_Bounds_Type;

   ------------------------------------
   -- Create_Array_Thin_Pointer_Type --
   ------------------------------------

   function Create_Array_Thin_Pointer_Type
     (Env        : Environ;
      Array_Type : Entity_Id) return Type_T
   is
      Elt_Type : constant Type_T :=
        Create_Type (Env, Component_Type (Array_Type));
      Arr_Type : constant Type_T :=
        LLVM.Core.Array_Type (Elt_Type, 0);
   begin
      return Pointer_Type (Arr_Type, 0);
   end Create_Array_Thin_Pointer_Type;

   -----------------------------------
   -- Create_Array_Fat_Pointer_Type --
   -----------------------------------

   function Create_Array_Fat_Pointer_Type
     (Env        : Environ;
      Array_Type : Entity_Id) return Type_T
   is
      St_Els : Type_Array (1 .. 2) :=
        (Create_Array_Thin_Pointer_Type (Env, Array_Type),
         Create_Array_Bounds_Type (Env, Array_Type));
   begin
      return Struct_Type (St_Els'Address, St_Els'Length, False);
   end Create_Array_Fat_Pointer_Type;

   ------------------------
   -- Create_Access_Type --
   ------------------------

   function Create_Access_Type
     (Env : Environ; TE : Entity_Id) return Type_T
   is
      T : constant Type_T := Create_Type (Env, TE);
   begin
      if Get_Type_Kind (T) = Array_Type_Kind
        and then not Is_Constrained (TE)
      then
         return Create_Array_Fat_Pointer_Type (Env, TE);

      --  LLVM subprograms values already are already pointers. We want to
      --  embed a static-link with them, though.

      elsif Ekind (TE) = E_Function
        or else Ekind (TE) = E_Procedure
        or else Ekind (TE) = E_Subprogram_Type
      then
         return Create_Subprogram_Access_Type (Env, T);

      else
         return Pointer_Type (T, 0);
      end if;
   end Create_Access_Type;

   -----------------
   -- Create_Type --
   -----------------

   function Create_Type (Env : Environ; TE : Entity_Id) return Type_T is
      Def_Ident : Entity_Id;
   begin
      --  First, return any already translated type from the environment, if
      --  any. Allow definition only for N_Defining_Identifier.

      if Env.Has_Type (TE) then
         return Env.Get (TE);
      end if;

      Def_Ident := Get_Fullest_View (TE);

      --  The full view may already be in the environment

      if Env.Has_Type (Def_Ident) then
         return Env.Get (Def_Ident);
      end if;

      case Ekind (Def_Ident) is

         when Discrete_Kind =>

            if Is_Modular_Integer_Type (Def_Ident) then
               return Int_Type_In_Context
                 (Env.Ctx,
                  Interfaces.C.unsigned (UI_To_Int (RM_Size (Def_Ident))));
            end if;

            return Int_Type_In_Context
              (Env.Ctx, Interfaces.C.unsigned (UI_To_Int (Esize (Def_Ident))));

         when E_Floating_Point_Type | E_Floating_Point_Subtype =>
            --  TODO??? Replace this dummy handler
            return Void_Type_In_Context (Env.Ctx);

         when E_Access_Type .. E_General_Access_Type
            | E_Anonymous_Access_Type
            | E_Access_Subprogram_Type =>
            return Create_Access_Type
              (Env, Designated_Type (Def_Ident));

         when Record_Kind =>
            declare
               function Rec_Comp_Filter (E : Entity_Id) return Boolean
               is (Ekind (E) in E_Component | E_Discriminant);

               function Iterate is new Iterate_Entities
                 (Get_First => First_Entity,
                  Get_Next  => Next_Entity,
                  Filter    => Rec_Comp_Filter);

               Struct_Type   : Type_T;
               Comps         : constant Entity_Iterator := Iterate (Def_Ident);
               LLVM_Comps    : array (1 .. Comps'Length) of Type_T;
               I             : Natural := 1;
               Struct_Num    : Nat := 1;
               Num_Fields    : Natural := 1;
               Info          : Record_Info;
               Fields        : Field_Info_Vectors.Vector;
               Current_Field : Field_Info;
               use Interfaces.C;

               function New_Struct_Info return Struct_Info is
                 ((LLVM_Type => Struct_Type, Preceding_Fields => Fields));

            begin
               Struct_Type := Struct_Create_Named
                 (Env.Ctx, Get_Name (Def_Ident));
               Info.Structs.Append (New_Struct_Info);

               --  Records enable some "type recursivity", so store this one in
               --  the environment so that there is no infinite recursion when
               --  nested components reference it.

               Env.Set (Def_Ident, Struct_Type);

               for Comp of Comps loop
                  LLVM_Comps (I) := Create_Type (Env, Etype (Comp));
                  Current_Field :=
                    (Struct_Num, Nat (I - 1), Comp, LLVM_Comps (I));
                  Fields.Append (Current_Field);
                  Info.Fields.Include (Comp, Current_Field);
                  I := I + 1;
                  Num_Fields := Num_Fields + 1;

                  --  If we are on a component which sizes depends on a
                  --  discriminant, we create a new struct type for the
                  --  following components.

                  if Size_Depends_On_Discriminant (Etype (Comp)) then
                     Struct_Set_Body
                       (Struct_Type, LLVM_Comps'Address,
                        unsigned (I - 1), False);
                     I := 1;
                     Struct_Num := Struct_Num + 1;

                     --  Only create a new struct if we have remaining fields
                     --  after this one

                     if Num_Fields < Comps'Length then
                        Struct_Type := Struct_Create_Named
                          (Env.Ctx, Get_Name (Def_Ident) & Img (Struct_Num));
                        Info.Structs.Append (New_Struct_Info);
                     end if;
                  end if;
               end loop;

               --  If there are components remaining, set them to be the
               --  current struct body

               if I > 1 then
                  Struct_Set_Body
                    (Struct_Type, LLVM_Comps'Address, unsigned (I - 1), False);
               end if;

               Env.Set (Def_Ident, Info);
               return Env.Get (Def_Ident);
            end;

         when Array_Kind =>
            declare
               Result     : Type_T :=
                 Create_Type (Env, Component_Type (Def_Ident));
               LB, HB     : Node_Id;
               Range_Size : Long_Long_Integer := 0;

               function Iterate is new Iterate_Entities
                 (Get_First => First_Index,
                  Get_Next  => Next_Index);
            begin
               --  Special case for string literals: they do not include
               --  regular index information.

               if Ekind (TE) = E_String_Literal_Subtype then
                  Range_Size := UI_To_Long_Long_Integer
                    (String_Literal_Length (Def_Ident));
                  return Array_Type
                    (Result, Interfaces.C.unsigned (Range_Size));
               end if;

               --  Wrap each "nested type" into an array using the previous
               --  index.

               for Index of reverse Iterate (Def_Ident) loop
                  declare
                     --  Sometimes, the frontends leaves an identifier that
                     --  references an integer subtype instead of a range.

                     Idx_Range : constant Node_Id := Get_Dim_Range (Index);

                  begin
                     LB := Low_Bound (Idx_Range);
                     HB := High_Bound (Idx_Range);
                  end;

                  --  Compute the size of this range if possible, otherwise
                  --  keep 0 for "unknown".

                  if Is_Constrained (TE)
                    and then Compile_Time_Known_Value (LB)
                    and then Compile_Time_Known_Value (HB)
                  then
                     Range_Size := Long_Long_Integer
                       (UI_To_Long_Long_Integer (Expr_Value (HB))
                        - UI_To_Long_Long_Integer (Expr_Value (LB)) + 1);
                  end if;

                  Result := Array_Type
                    (Result, Interfaces.C.unsigned (Range_Size));
               end loop;
               return Result;
            end;

         when E_Subprogram_Type =>
            --  An access to a subprogram can point any subprogram (nested or
            --  not), so it must accept a static link.

            return Create_Subprogram_Type_From_Entity
              (Env, Def_Ident, Takes_S_Link => True);

         when E_Anonymous_Access_Subprogram_Type =>
            return Create_Access_Type
              (Env, Designated_Type (Def_Ident));

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Unhandled type kind: "
              & Entity_Kind'Image (Ekind (Def_Ident));
            pragma Annotate (Xcov, Exempt_Off);
      end case;
   end Create_Type;

   --------------------------
   -- Create_Discrete_Type --
   --------------------------

   procedure Create_Discrete_Type
     (Env       : Environ;
      TE        : Entity_Id;
      TL        : out Type_T;
      Low, High : out Value_T) is
      SRange : Node_Id;
   begin
      --  Delegate LLVM Type creation to Create_Type

      TL := Create_Type (Env, TE);

      --  Compute ourselves the bounds

      case Ekind (TE) is
         when E_Enumeration_Type | E_Enumeration_Subtype
            | E_Signed_Integer_Type | E_Signed_Integer_Subtype
            | E_Modular_Integer_Type | E_Modular_Integer_Subtype =>

            SRange := Scalar_Range (TE);
            case Nkind (SRange) is
               when N_Range =>
                  Low := GNATLLVM.Compile.Emit_Expression
                    (Env, Low_Bound (SRange));
                  High := GNATLLVM.Compile.Emit_Expression
                    (Env, High_Bound (SRange));
               when others =>
                  pragma Annotate (Xcov, Exempt_On, "Defensive programming");
                  raise Program_Error
                    with "Invalid scalar range: "
                    & Node_Kind'Image (Nkind (SRange));
                  pragma Annotate (Xcov, Exempt_Off);
            end case;

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Invalid discrete type: " & Entity_Kind'Image (Ekind (TE));
            pragma Annotate (Xcov, Exempt_Off);
      end case;
   end Create_Discrete_Type;

   -----------------------------
   -- Create_Static_Link_Type --
   -----------------------------

   function Create_Static_Link_Type
     (Env         : Environ;
      S_Link_Desc : Static_Link_Descriptor) return Type_T
   is
      Types : array (1 .. Natural (S_Link_Desc.Closure.Length) + 1) of Type_T;
      I     : Natural := 2;
   begin
      --  The first element points to the parent static link

      Types (1) :=
        (if S_Link_Desc.Parent /= null
         then Pointer_Type
           (Create_Static_Link_Type (Env, S_Link_Desc.Parent),
            0)
         else Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0));

      --  The following elements point to the variables this closure give
      --  access to.

      for Def_Ident of S_Link_Desc.Closure loop
         Types (I) := Create_Access_Type (Env, Etype (Def_Ident));
         I := I + 1;
      end loop;
      return Struct_Type_In_Context
        (Env.Ctx, Types'Address, Types'Length, Packed => False);
   end Create_Static_Link_Type;

   --------------------------------------
   -- Create_Subprogram_Type_From_Spec --
   --------------------------------------

   function Create_Subprogram_Type_From_Spec
     (Env : Environ; Subp_Spec : Node_Id) return Type_T
   is
      Def_Ident    : constant Entity_Id := Defining_Unit_Name (Subp_Spec);
      Params       : constant Entity_Iterator  := Get_Params (Def_Ident);
   begin

      return Create_Subprogram_Type
        (Env,
         Params,
         (case Nkind (Subp_Spec) is
             when N_Procedure_Specification =>
                Empty,
             when N_Function_Specification =>
                Entity (Result_Definition (Subp_Spec)),
             when others =>
                raise Program_Error
                  with "Invalid node: "
          & Node_Kind'Image (Nkind (Subp_Spec))),
        Env.Takes_S_Link (Defining_Unit_Name (Subp_Spec)));
   end Create_Subprogram_Type_From_Spec;

   ----------------------------------------
   -- Create_Subprogram_Type_From_Entity --
   ----------------------------------------

   function Create_Subprogram_Type_From_Entity
     (Env           : Environ;
      Subp_Type_Ent : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T is
   begin
      return Create_Subprogram_Type
        (Env,
         Get_Params (Subp_Type_Ent),
         (if Etype (Subp_Type_Ent) = Standard_Void_Type
          then Empty
          else Etype (Subp_Type_Ent)),
         Takes_S_Link);
   end Create_Subprogram_Type_From_Entity;

   ----------------------------
   -- Create_Subprogram_Type --
   ----------------------------

   function Create_Subprogram_Type
     (Env           : Environ;
      Params        : Entity_Iterator;
      Return_Type   : Entity_Id;
      Takes_S_Link  : Boolean) return Type_T
   is
      Args_Count   : constant Int :=
        Params'Length + (if Takes_S_Link then 1 else 0);
      Arg_Types    : Type_Array (1 .. Args_Count);
   begin
      --  First, Associate an LLVM type for each Ada subprogram parameter

      for I in Params'Range loop
         declare
            Param_Ent  : constant Entity_Id := Params (I);
            Param_Type : constant Node_Id := Etype (Param_Ent);
         begin
            --  If this is an out parameter, or a parameter whose type is
            --  unconstrained, take a pointer to the actual parameter.

            Arg_Types (I) :=
              (if Param_Needs_Ptr (Param_Ent)
               then Create_Access_Type (Env, Param_Type)
               else Create_Type (Env, Param_Type));
         end;
      end loop;

      --  Set the argument for the static link, if any

      if Takes_S_Link then
         Arg_Types (Arg_Types'Last) :=
           Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0);
      end if;

      return Fn_Ty
        (Arg_Types,
         (if Present (Return_Type)
          then Create_Type (Env, Return_Type)
          else Void_Type_In_Context (Env.Ctx)));
   end Create_Subprogram_Type;

   -----------------------------------
   -- Create_Subprogram_Access_Type --
   -----------------------------------

   function Create_Subprogram_Access_Type
     (Env : Environ;
      Subp_Type : Type_T) return Type_T
   is
      Couple : constant Type_Array (1 .. 2) :=
        (Pointer_Type (Subp_Type, 0),
         Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0));
   begin
      return Struct_Type_In_Context
        (Env.Ctx,
         Couple'Address, Couple'Length,
         Packed => False);
   end Create_Subprogram_Access_Type;

end GNATLLVM.Types;
