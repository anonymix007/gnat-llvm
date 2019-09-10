------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2019, AdaCore                     --
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

with Ada.Unchecked_Conversion;

with Get_Targ; use Get_Targ;

with Output; use Output;
with Sprint; use Sprint;

with GNATLLVM.Arrays;        use GNATLLVM.Arrays;
with GNATLLVM.Arrays.Create; use GNATLLVM.Arrays.Create;
with GNATLLVM.Conversions;   use GNATLLVM.Conversions;
with GNATLLVM.Environment;   use GNATLLVM.Environment;
with GNATLLVM.GLType;        use GNATLLVM.GLType;
with GNATLLVM.Instructions;  use GNATLLVM.Instructions;
with GNATLLVM.Subprograms;   use GNATLLVM.Subprograms;
with GNATLLVM.Types;         use GNATLLVM.Types;
with GNATLLVM.Utils;         use GNATLLVM.Utils;
with GNATLLVM.Variables;     use GNATLLVM.Variables;

package body GNATLLVM.GLValue is

   function GL_Value_Is_Valid_Int (V : GL_Value_Base) return Boolean;
   --  Internal version of GL_Value_Is_Valid

   function Object_Can_Be_Data (V : GL_Value_Base) return Boolean is
     (not Is_Nonnative_Type (V.Typ)
        and then (Is_Loadable_Type (V.Typ)
                    or else (Is_Data (V.Relationship)
                               and then (Is_Constant (V.Value)
                                           or else Is_Undef (V.Value)))));
   --  Return True if it's appropriate to use Data for V when converting to
   --  a GL_Relationship of Object.  Since this is called from
   --  GL_Value_Is_Valid, we have to be careful not to call any function
   --  that takes a GL_Value as an operand.

   -----------------------
   -- GL_Value_Is_Valid --
   -----------------------

   function GL_Value_Is_Valid (V : GL_Value_Base) return Boolean is
      Valid : constant Boolean := GL_Value_Is_Valid_Int (V);
   begin
      --  This function exists so a conditional breakpoint can be set at
      --  the following line to see the invalid value.  Otherwise, there
      --  seems no other reasonable way to get to see it.

      return Valid;
   end GL_Value_Is_Valid;

   ----------------------------
   --  GL_Value_Is_Valid_Int --
   ----------------------------

   function GL_Value_Is_Valid_Int (V : GL_Value_Base) return Boolean is
      GT   : constant GL_Type     :=
        (if V = No_GL_Value then No_GL_Type else V.Typ);
      Val  : constant Value_T     := V.Value;
      Kind : constant Type_Kind_T :=
        (if No (Val) then Void_Type_Kind else Get_Type_Kind (Type_Of (Val)));

   begin
      --  We have to be very careful in this function not to call any
      --  functions that take a GL_Value as an operand to avoid infinite
      --  recursion.  So we can't call "No" below, for example.

      if V = No_GL_Value then
         return True;
      elsif No (Val) or else No (GT) then
         return False;
      end if;

      case V.Relationship is
         when Data | Boolean_And_Data =>

            --  We allow a non-loadable type to be Data to handle cases
            --  such as passing large objects by value.  We don't want to
            --  generate such unless we have to, but we also don't want to
            --  generate such unless we have to, but we also don't want
            --  to make it invalid.  We can't use Data for a dynamic
            --  size type, though.
            return Ekind (GT) /= E_Subprogram_Type
              and then not Is_Nonnative_Type (GT);

         when Boolean_Data =>
            return GT = Boolean_GL_Type;

         when Reference =>
            return (Kind = Pointer_Type_Kind
                      or else Ekind (GT) = E_Subprogram_Type);

         when Reference_To_Reference | Reference_To_Thin_Pointer =>
            return Kind = Pointer_Type_Kind;

         when Fat_Pointer | Bounds | Bounds_And_Data =>
            return Is_Array_Or_Packed_Array_Type (GT);

         when  Thin_Pointer
            | Reference_To_Bounds | Reference_To_Bounds_And_Data =>
            return Kind = Pointer_Type_Kind
              and then Is_Array_Or_Packed_Array_Type (GT);

         when Activation_Record  | Fat_Reference_To_Subprogram =>
            return Ekind (GT) in E_Subprogram_Type | E_Access_Subprogram_Type;

         when Reference_To_Activation_Record =>
            return Ekind (GT) = E_Subprogram_Type
              and then Kind = Pointer_Type_Kind;

         when Reference_To_Subprogram | Reference_To_Ref_To_Subprogram
            | Reference_To_Unknown =>
            return Kind = Pointer_Type_Kind;

         when Trampoline =>

            --  We'd like to test TE to see that it's a subprogram type,
            --  but if we're making this trampoline because of a 'Address,
            --  we don't have any subprogram type in sight.

            return Kind = Pointer_Type_Kind;

         when Unknown =>
            return True;

         when others =>
            return False;
      end case;
   end GL_Value_Is_Valid_Int;

   ---------------
   -- Operators --
   ---------------

   function "<" (LHS : GL_Value; RHS : Int) return Boolean is
     (LHS < Const_Int (LHS, UI_From_Int (RHS)));
   function "<=" (LHS : GL_Value; RHS : Int) return Boolean is
     (LHS <= Const_Int (LHS, UI_From_Int (RHS)));
   function ">" (LHS : GL_Value; RHS : Int) return Boolean is
     (LHS > Const_Int (LHS, UI_From_Int (RHS)));
   function ">=" (LHS : GL_Value; RHS : Int) return Boolean is
     (LHS >= Const_Int (LHS, UI_From_Int (RHS)));
   function "=" (LHS : GL_Value; RHS : Int) return Boolean is
     (LHS = Const_Int (LHS, UI_From_Int (RHS)));

   ------------------
   -- Not_Pristine --
   ------------------

   function Not_Pristine (V : GL_Value) return GL_Value is
      Result : GL_Value := G_From (LLVM_Value (V), V);
   begin
      Result.Is_Pristine := False;
      return Result;
   end Not_Pristine;

   -------------------
   -- Mark_Volatile --
   -------------------

   function Mark_Volatile
     (V : GL_Value; Flag : Boolean := True) return GL_Value
   is
      Result : GL_Value := G_From (LLVM_Value (V), V);
   begin
      Result.Is_Volatile := Result.Is_Volatile or Flag;
      return Result;
   end Mark_Volatile;

   -----------------
   -- Mark_Atomic --
   -----------------

   function Mark_Atomic
     (V : GL_Value; Flag : Boolean := True) return GL_Value
   is
      Result : GL_Value := G_From (LLVM_Value (V), V);
   begin
      Result.Is_Atomic := Result.Is_Atomic or Flag;
      return Result;
   end Mark_Atomic;

   ---------------------
   -- Mark_Overflowed --
   ---------------------

   function Mark_Overflowed
     (V : GL_Value; Flag : Boolean := True) return GL_Value
   is
      Result : GL_Value := G_From (LLVM_Value (V), V);
   begin
      Result.Overflowed := Result.Overflowed or Flag;
      return Result;
   end Mark_Overflowed;

   ----------------------
   -- Clear_Overflowed --
   ----------------------

   function Clear_Overflowed (V : GL_Value) return GL_Value is
      Result : GL_Value := G_From (LLVM_Value (V), V);
   begin
      Result.Overflowed := False;
      return Result;
   end Clear_Overflowed;

   ----------------
   -- Full_Etype --
   ----------------

   function Full_Etype (V : GL_Value) return Entity_Id is
     (Full_Etype (Related_Type (V)));

   ----------------------------
   -- Is_Unconstrained_Array --
   ----------------------------

   function Is_Unconstrained_Array (V : GL_Value) return Boolean is
     (Is_Unconstrained_Array (Related_Type (V)));

   -----------------------------------
   -- Is_Access_Unconstrained_Array --
   -----------------------------------

   function Is_Access_Unconstrained_Array (V : GL_Value) return Boolean is
     (Is_Access_Type (V) and then not Is_Subprogram_Reference (V)
        and then Is_Unconstrained_Array (Full_Designated_Type (V))
        and then Relationship (V) /= Reference);

   -------------------------------
   -- Is_Packed_Array_Impl_Type --
   -------------------------------

   function Is_Packed_Array_Impl_Type (V : GL_Value) return Boolean is
     (Is_Packed_Array_Impl_Type (Related_Type (V)));

   -----------------------------
   -- Is_Unconstrained_Record --
   -----------------------------

   function Is_Unconstrained_Record (V : GL_Value) return Boolean is
     (Is_Unconstrained_Record (Related_Type (V)));

   ---------------------------
   -- Is_Unconstrained_Type --
   ---------------------------

   function Is_Unconstrained_Type (V : GL_Value) return Boolean is
     (Is_Unconstrained_Type (Related_Type (V)));

   -----------------------------------
   -- Is_Constr_Subt_For_UN_Aliased --
   -----------------------------------

   function Is_Constr_Subt_For_UN_Aliased (V : GL_Value) return Boolean is
     (Is_Constr_Subt_For_UN_Aliased (Related_Type (V)));

   -----------------------------------
   -- Is_Bit_Packed_Array_Impl_Type --
   -----------------------------------

   function Is_Bit_Packed_Array_Impl_Type (V : GL_Value) return Boolean is
     (Is_Bit_Packed_Array_Impl_Type (Related_Type (V)));

   ----------------------
   -- Is_Unsigned_Type --
   ----------------------

   function Is_Unsigned_Type (V : GL_Value) return Boolean is
     (not Is_Reference (V) and then Is_Unsigned_Type (Related_Type (V)));

   -----------------------
   -- Type_Needs_Bounds --
   -----------------------

   function Type_Needs_Bounds (V : GL_Value) return Boolean is
     (Type_Needs_Bounds (Related_Type (V)));

   ---------------------
   -- Is_Dynamic_Size --
   ---------------------

   function Is_Dynamic_Size (V : GL_Value) return Boolean is
     (Is_Dynamic_Size (Related_Type (V)));

   -----------------------------
   -- Is_Nonsymbolic_Constant --
   -----------------------------

   function Is_Nonsymbolic_Constant (V : GL_Value) return Boolean is
     (Is_Nonsymbolic_Constant (LLVM_Value (V)));

   -----------------------
   -- Is_Nonnative_Type --
   -----------------------

   function Is_Nonnative_Type (V : GL_Value) return Boolean is
     (Is_Nonnative_Type (Related_Type (V)));

   ----------------------
   -- Is_Loadable_Type --
   ----------------------

   function Is_Loadable_Type (V : GL_Value) return Boolean is
     (Is_Data (V) or else Is_Loadable_Type (Related_Type (V)));

   -------------
   -- Discard --
   -------------

   procedure Discard (V : GL_Value) is
      pragma Unreferenced (V);
   begin
      null;
   end Discard;

   ---------------------------
   --  Relationship_For_Ref --
   ---------------------------

   function Relationship_For_Ref (GT : GL_Type) return GL_Relationship is
     (Relationship_For_Ref (Full_Etype (GT)));

   ---------------------------
   --  Relationship_For_Ref --
   ---------------------------

   function Relationship_For_Ref (TE : Entity_Id) return GL_Relationship is
   begin
      --  If this is an unconstrained array, this is a fat pointer

      if Is_Array_Type (TE) and then not Is_Constrained (TE) then
         return Fat_Pointer;

      --  If this type is created as a a nominal subtype of an
      --  unconstrained type for an aliased object, in order to point
      --  to the data, we need a thin pointer.

      elsif Type_Needs_Bounds (TE) then
         return Thin_Pointer;

      --  If this is an access to subprogram, this is a pair of pointers
      --  that includes the activation record unless it's a foreign
      --  convention, in which case it's a trampoline.

      elsif Ekind (TE) = E_Subprogram_Type then
         return (if   Has_Foreign_Convention (TE) then Trampoline
                 else Fat_Reference_To_Subprogram);

      --  Otherwise,  it's just a Reference

      else
         return Reference;
      end if;
   end Relationship_For_Ref;

   ----------------------------------
   -- Relationship_For_Access_Type --
   ----------------------------------

   function Relationship_For_Access_Type (GT : GL_Type) return GL_Relationship
   is
      TE   : constant Entity_Id        := Full_Etype (GT);
      R    : constant GL_Relationship  := Relationship_For_Access_Type (TE);
      Size : constant GL_Value         := Get_Type_Size (GT);

   begin
      --  If this would be a fat pointer, but the size of the GL_Type
      --  corresponds to that of a thin pointer, use it.

      if R = Fat_Pointer and then Size = Get_Pointer_Size then
         return Thin_Pointer;

      --  And vice versa

      elsif R = Thin_Pointer and then Size = Get_Pointer_Size * 2 then
         return Fat_Pointer;
      else
         return R;
      end if;
   end Relationship_For_Access_Type;

   ----------------------------------
   -- Relationship_For_Access_Type --
   ----------------------------------

   function Relationship_For_Access_Type
     (TE : Entity_Id) return GL_Relationship
   is
      BT : constant Entity_Id       := Full_Base_Type (TE);
      DT : constant Entity_Id       := Full_Designated_Type (BT);
      R  : constant GL_Relationship := Relationship_For_Ref (DT);
      --  A subtype always has the same representation as its base type.
      --  This is true for access types as well.

   begin
      --  If we would use a fat pointer, but the access type is forced
      --  to a single word, use a thin pointer.

      if R = Fat_Pointer and then RM_Size (TE) = Get_Pointer_Size then
         return Thin_Pointer;

      --  Similarly for foreign convention access to subprogram

      elsif R = Fat_Reference_To_Subprogram
        and then (Has_Foreign_Convention (TE)
                    or else not Can_Use_Internal_Rep (TE))
      then
         return Trampoline;
      else
         return R;
      end if;

   end Relationship_For_Access_Type;

   ----------------------------
   -- Relationship_For_Alloc --
   ----------------------------

   function Relationship_For_Alloc (GT : GL_Type) return GL_Relationship is
     (Relationship_For_Alloc (Full_Etype (GT)));

   ----------------------------
   -- Relationship_For_Alloc --
   ----------------------------

   function Relationship_For_Alloc (TE : Entity_Id) return GL_Relationship is
      R  : constant GL_Relationship := Relationship_For_Ref (TE);
      GT : constant GL_Type         := Default_GL_Type (TE);
   begin
      --  The difference here is when we need to allocate both bounds
      --  and data.  We do this for string literals because they are most
      --  commonly used in situations where they're passed as parameters
      --  where the formal is a String.

      if Is_Unconstrained_Array (GT) or else Type_Needs_Bounds (GT)
        or else Ekind (GT) = E_String_Literal_Subtype
      then
         return Reference_To_Bounds_And_Data;
      else
         return R;
      end if;

   end Relationship_For_Alloc;

   ---------------------------
   -- Type_For_Relationship --
   ---------------------------

   function Type_For_Relationship
     (GT : GL_Type; R : GL_Relationship) return Type_T
   is
      T       : constant Type_T  := Type_Of (GT);
      P_T : constant Type_T      := Pointer_Type (T, 0);
      TE  : constant Entity_Id   := Full_Etype (GT);

   begin
      --  If this is a reference to some other relationship, get the type for
      --  that relationship and make a pointer to it.

      if Deref (R) /= Invalid then
         return Pointer_Type (Type_For_Relationship (GT, Deref (R)), 0);
      end if;

      --  Handle all other relationships here

      case R is
         when Data =>
            return T;

         when Boolean_Data =>
            return Bit_T;

         when Boolean_And_Data =>
            return Build_Struct_Type ((1 => T, 2 => Bit_T));

         when Object =>
            return (if Is_Loadable_Type (GT) then T else P_T);

         when Thin_Pointer | Any_Reference =>
            return P_T;

         when Activation_Record =>
            return Byte_T;

         when Fat_Pointer =>
            return Create_Array_Fat_Pointer_Type (GT);

         when Bounds =>
            return Create_Array_Bounds_Type (TE);

         when Bounds_And_Data =>
            return Create_Array_Bounds_And_Data_Type (TE, T);

         when Trampoline =>
            return Void_Ptr_Type;

         when Fat_Reference_To_Subprogram =>
            return Create_Subprogram_Access_Type;

         when others =>
            pragma Assert (False);
            return Void_Ptr_Type;
      end case;
   end Type_For_Relationship;

   ---------------------------
   -- Type_For_Relationship --
   ---------------------------

   function Type_For_Relationship
     (TE : Entity_Id; R : GL_Relationship) return Type_T is
   begin
      --  Normally, we'd factor out the calls to Type_Of and Pointer_Type,
      --  but since we're called when creating an access type and that
      --  function knows when we actually need to elaborate the designated
      --  type, only call those functions when we know we need to.

      --  If this is a reference to some other relationship, get the type for
      --  that relationship and make a pointer to it.

      if Deref (R) /= Invalid then
         return Pointer_Type (Type_For_Relationship (TE, Deref (R)), 0);
      end if;

      --  Handle all other relationships here

      case R is
         when Data =>
            return Type_Of (TE);

         when Boolean_Data =>
            return Bit_T;

         when Boolean_And_Data =>
            return Build_Struct_Type ((1 => Type_Of (TE), 2 => Bit_T));

         when Object =>
            return (if   Is_Loadable_Type (Default_GL_Type (TE))
                    then Type_Of (TE) else Pointer_Type (Type_Of (TE), 0));

         when Thin_Pointer | Any_Reference =>
            return Pointer_Type (Type_Of (TE), 0);

         when Activation_Record =>
            return Byte_T;

         when Fat_Pointer =>
            return Create_Array_Fat_Pointer_Type (TE);

         when Bounds =>
            return Create_Array_Bounds_Type (TE);

         when Bounds_And_Data =>
            return Build_Struct_Type ((1 => Create_Array_Bounds_Type (TE),
                                       2 => Type_Of (TE)));

         when Trampoline =>
            return Void_Ptr_Type;

         when Fat_Reference_To_Subprogram =>
            return Create_Subprogram_Access_Type;

         when others =>
            pragma Assert (False);
            return Void_Ptr_Type;
      end case;
   end Type_For_Relationship;

   ------------------------
   -- Equiv_Relationship --
   ------------------------

   function Equiv_Relationship
     (V : GL_Value; Rel : GL_Relationship) return Boolean
   is
      R : GL_Relationship := Rel;

   begin
      if R = Object then
         R := (if Is_Data (V) or else Object_Can_Be_Data (V) then Data
               else Any_Reference);
      end if;

      return Relationship (V) = R
        or else (R = Any_Reference and then Is_Any_Reference (V))
        or else (R = Reference_For_Integer and then Is_Any_Reference (V)
                   and then Relationship (V) /= Fat_Pointer
                   and then Relationship (V) /= Fat_Reference_To_Subprogram);

   end Equiv_Relationship;

   ---------------
   -- Set_Value --
   ---------------

   procedure Set_Value (VE : Entity_Id; VL : GL_Value) is
   begin
      Set_Value_R (VE, Not_Pristine (VL));
   end Set_Value;

   ---------
   -- Get --
   ---------

   function Get (V : GL_Value; Rel : GL_Relationship) return GL_Value is
      GT     : constant GL_Type         := Related_Type (V);
      Our_R  : constant GL_Relationship := Relationship (V);
      R      : GL_Relationship          := Rel;
      Result : GL_Value;

   begin
      --  Handle relationship of Object by converting it to the appropriate
      --  relationship for TE and V.

      if R = Object then
         R := (if   Object_Can_Be_Data (V) or else Is_Data (V) then Data
               else Any_Reference);
      end if;

      --  If we want any single-word relationship, we can convert everything
      --  to Reference, except for Reference_To_Subprogram and Trampoline,
      --  which are also OK.

      if R = Reference_For_Integer then
         R := (if   Relationship (V) in Reference_To_Subprogram | Trampoline
               then Relationship (V) else Reference);
      end if;

      --  If it's already the desired relationship, done

      if Equiv_Relationship (V, R) then
         return V;

      --  If we just need a dereference, do that

      elsif Equiv_Relationship (Deref (Our_R), R) then
         return Load (V);

      --  Likewise for a double dereference

      elsif Equiv_Relationship (Deref (Deref (Our_R)), R) then
         return Load (Load (V));

      --  If this is a double reference and we need something that's a
      --  single reference (the above only checks that a need only do the
      --  dereference), do a dereference and then get what we need.

      elsif Is_Double_Reference (Our_R) and then Is_Single_Reference (R) then
         return Get (Get (V, Deref (Our_R)), R);

      --  If converting one double reference to another, just convert the
      --  pointer.

      elsif Is_Double_Reference (Our_R) and then Is_Double_Reference (R) then
         return Ptr_To_Relationship (V, GT, R);

      --  If we just need to make this into a reference, we can store it
      --  into memory since we only have those relationships if this is a
      --  actual LLVM value.  If we have a constant, we should put it in
      --  static memory.  Not only is it more efficient to do this at
      --  compile-time, but if these are bounds of an array, we may be
      --  passing them using 'Unrestricted_Access and will have problems if
      --  it's on the stack of the calling subprogram since the called
      --  subprogram may capture the address and store it for later (this
      --  happens a lot with tasking).  If we have a string literal, we
      --  also materialize the bounds if we can.

      elsif Equiv_Relationship (Ref (Our_R), R) then
         if Is_Constant (V) then
            return Get (Make_Global_Constant (V), R);
         else
            declare
               T       : constant Type_T        := Type_Of (V);
               Promote : constant Basic_Block_T := Maybe_Promote_Alloca (T);
               Inst    : constant Value_T       := Alloca (IR_Builder, T, "");

            begin
               Set_Object_Align (Inst, GT, Empty);
               Done_Promoting_Alloca (Inst, Promote, T);
               Result := G (Inst, GT, Ref (Our_R));
               Store (V, Result);
               return Result;
            end;
         end if;
      end if;

      --  Now we have specific rules for each relationship type.  It's tempting
      --  to automate the cases where we do recursive calls by computing which
      --  cases are possible here directly and searching for an intermediate
      --  relationship, but that could easily make a bad choice.

      case R is
         when Data =>
            --  If we have bounds and data, extract the data

            if Our_R = Bounds_And_Data then
               return Extract_Value (GT, V, Data_Index_In_BD_Type (V));

               --  If we have a reference to something else, try to convert
               --  to a normal reference and then get the data.  If this
               --  was reference to bounds and data, we could also just
               --  dereference and extract the data, but that involves
               --  more memory accesses.

            elsif Is_Reference (V) then
               return Get (Get (V, Reference), R);

               --  If we have Boolean_Data, extend it

            elsif Our_R = Boolean_Data then
               return Z_Ext (V, GT);

            --  From Boolean_And_Data, extract the data

            elsif Our_R = Boolean_And_Data then
               return Extract_Value (GT, V, 0);
            end if;

         when Boolean_Data =>

            --  To get Boolean_Data from Data, truncate it

            if Our_R = Data then
               return Trunc_To_Relationship (V, Bit_T, Boolean_Data);

            --  And from Boolean_And_Data, extract it

            elsif Our_R = Boolean_And_Data then
               return Extract_Value_To_Relationship (Boolean_GL_Type, V, 1, R);
            end if;

         when Bounds =>

            --  If we have something that we can use to get the address of
            --  bounds, convert to that and then dereference.

            if Our_R in Fat_Pointer | Thin_Pointer |
              Reference_To_Thin_Pointer | Reference_To_Bounds_And_Data
            then
               return Load (Get (V, Reference_To_Bounds));

            --  If we have both bounds and data, extract the bounds

            elsif Our_R = Bounds_And_Data then
               return Extract_Value_To_Relationship (GT, V, 0, R);

            --  Otherwise, compute the bounds from the type (pass in V
            --  just in case, though we should have handled all the cases
            --  where it's useful above).

            else
               return Get_Array_Bounds (GT, GT, V);
            end if;

         when Bounds_And_Data =>

            --  If we have data, we can add the bounds

            if Our_R = Data then
               Result := Get_Undef_Relationship (GT, R);
               return Insert_Value
                 (Insert_Value (Result, Get_Array_Bounds (GT, GT, V), 0),
                  V, Data_Index_In_BD_Type (Result));
            end if;

         when Reference_To_Bounds =>

            --  If we have a fat pointer, part of it is a pointer to the
            --  bounds.

            if Our_R = Fat_Pointer then
               return Extract_Value_To_Relationship (GT, V, 1, R);

            --  A reference to bounds and data is a reference to bounds;
            --  we just get the address of the first field.

            elsif Our_R = Reference_To_Bounds_And_Data then
               return GEP_Idx_To_Relationship (GT, R, V, (1 => 0, 2 => 0));

            --  The bounds are in front of the data for a thin pointer

            elsif Our_R = Thin_Pointer then
               Result := Ptr_To_Size_Type (V) - To_Bytes (Get_Bound_Size (GT));
               return Int_To_Relationship (Result, GT, R);
            elsif Our_R = Reference_To_Thin_Pointer then
               return Get (Get (V, Thin_Pointer), R);

            --  Otherwise get the bounds and force them into memory

            else
               Result := Get (V, Bounds);
               return Get (Get (V, Bounds), R);
            end if;

         when Reference_To_Bounds_And_Data =>

            --  If we have a fat pointer, part of it is a pointer to the
            --  bounds, which should point to the data in any case where
            --  the language allows such a reference.

            if Our_R = Fat_Pointer then
               return Ptr_To_Relationship
                 (Extract_Value_To_Relationship
                    (GT, V, 1, Reference_To_Bounds),
                  GT, R);

            --  The bounds are in front of the data for a thin pointer

            elsif Our_R = Thin_Pointer then
               Result := Ptr_To_Size_Type (V) - To_Bytes (Get_Bound_Size (GT));
               return Int_To_Relationship (Result, GT, R);
            elsif Our_R = Reference_To_Thin_Pointer then
               return Get (Get (V, Thin_Pointer), R);

            --  If we have data, we can get the bounds and data from it

            elsif Our_R = Data then
               return Get (Get (V, Bounds_And_Data), R);
            end if;

         when Reference =>

            --  For Thin_Pointer, we have the value we need, possibly just
            --  converting it.  For fat pointer, we can extract it.

            if Our_R in Thin_Pointer | Trampoline then
               return Ptr_To_Relationship (V, GT, R);
            elsif Our_R = Reference_To_Thin_Pointer then
               return Get (Get (V, Thin_Pointer), R);
            elsif Our_R = Fat_Pointer then
               return Extract_Value_To_Relationship (GT, V, 0, R);
            elsif Our_R = Fat_Reference_To_Subprogram then
               return
                 Ptr_To_Relationship (Extract_Value_To_Ref (GT, V, 0), GT, R);

            --  If we have a reference to both bounds and data, we can
            --  compute where the data starts.  If we have the actual
            --  bounds and data, we can store them and proceed as above.

            elsif Our_R = Reference_To_Bounds_And_Data then
               return
                 GEP_Idx_To_Relationship (GT, R, V,
                                          (1 => 0,
                                           2 => Data_Index_In_BD_Type (V)));
            elsif Our_R = Bounds_And_Data then
               return Get (Get (V, Reference_To_Bounds_And_Data), R);
            end if;

         when Thin_Pointer =>

            --  There are only two cases where we can make a thin pointer.
            --  One is where we have the address of bounds and data (or the
            --  bounds and data themselves).  The other is if we have a fat
            --  pointer.  In the latter case, we can't know directly that
            --  the address in the fat pointer is actually suitable, but
            --  Ada language rules guarantee that it will be.

            if Our_R = Reference_To_Bounds_And_Data then
               return
                 GEP_Idx_To_Relationship (GT, R, V,
                                          (1 => 0,
                                           2 => Data_Index_In_BD_Type (V)));
            elsif Our_R = Bounds_And_Data then
               return Get (Get (V, Reference_To_Bounds_And_Data), R);
            elsif Our_R = Fat_Pointer then
               return Extract_Value_To_Relationship (GT, V, 0, R);
            elsif Our_R = Data then
               return Get (Get (V, Bounds_And_Data), R);
            end if;

         when Fat_Pointer =>

            --  To make a fat pointer, we make the address of the bounds
            --  and the address of the data and put them together.

            declare
               Val     : constant GL_Value :=
                 (if Is_Reference (V) then V else Get (V, Ref (Our_R)));
               --  If we have something that isn't a reference, start by
               --  getting a reference to it.

               Data_P  : constant GL_Value := Remove_Padding (Val);
               N_GT    : constant GL_Type  := Related_Type (Data_P);
               Fat_Ptr : constant GL_Value := Get_Undef_Relationship (N_GT, R);
               Bounds  : constant GL_Value := Get (Val, Reference_To_Bounds);
               Data    : constant GL_Value := Get (Data_P, Reference);

            begin
               return Insert_Value (Insert_Value (Fat_Ptr, Data, 0),
                                    Bounds,  1);
            end;

         when Reference_To_Activation_Record =>

            --  The activation record is inside a fat reference to a
            --  subprogram.  Otherwise, we make an undefined one.

            if Our_R = Fat_Reference_To_Subprogram then
               return Extract_Value_To_Relationship (GT, V, 1, R);
            else
               return Get_Undef_Relationship (GT, R);
            end if;

         when Fat_Reference_To_Subprogram =>

            --  If we want a fat reference to a subprogram, make one with
            --  an undefined static link.

            if Our_R in Reference | Trampoline then
               return Insert_Value (Get_Undef_Relationship (GT, R),
                                    Convert_To_Access (V, A_Char_GL_Type), 0);
            end if;

         when Trampoline =>

            --  LLVM doesn't allow making a trampoline from an arbitrary
            --  address.  So all we can do here is to just use the function
            --  address and hope that we don't need the static link.
            --  For all valid Ada operations, this is the case, but this
            --  may be an issue if people do wierd stuff.

            if Our_R = Fat_Reference_To_Subprogram then
               return Extract_Value_To_Relationship (GT, V, 0, R);
            elsif Our_R = Reference then
               return Get (Get (V, Fat_Reference_To_Subprogram), R);
            end if;

         when Any_Reference =>

            --  Two cases where we have some GL_Value that's not already
            --  handled by one of the cases above the "case" statement is
            --  if it's a Reference_To_Bounds_And_Data, in which case the
            --  most general thing to convert it to is a thin pointer.

            if Our_R = Reference_To_Bounds_And_Data then
               return Get (V, Thin_Pointer);
            end if;

         when others =>
            null;

      end case;

      --  If we reach here, this is case we can't handle.  Return null, which
      --  will cause our postcondition to fail.
      return No_GL_Value;
   end Get;

   ---------------
   -- To_Access --
   ---------------

   function To_Access (V : GL_Value; GT : GL_Type) return GL_Value is
     (G (LLVM_Value (V), GT));

   -----------------
   -- From_Access --
   -----------------

   function From_Access (V : GL_Value) return GL_Value is
      GT     : constant GL_Type         := Related_Type (V);
      Acc_GT : constant GL_Type         := Full_Designated_GL_Type (V);
      R      : constant GL_Relationship := Relationship_For_Access_Type (GT);

   begin
      return G (LLVM_Value (V), Acc_GT, R);
   end From_Access;

   ----------------------
   -- Set_Object_Align --
   ----------------------

   procedure Set_Object_Align (Obj : Value_T; GT : GL_Type; E : Entity_Id) is
      GT_Align : constant Nat := Get_Type_Alignment (GT);
      E_Align  : constant Nat :=
        (if   Present (E) and then Known_Alignment (E)
         then UI_To_Int (Alignment (E)) else BPU);

   begin
      Set_Alignment (Obj, unsigned (To_Bytes (Nat'Max (GT_Align, E_Align))));
   end Set_Object_Align;

   ----------------------
   -- Set_Object_Align --
   ----------------------

   procedure Set_Object_Align (Obj : GL_Value; GT : GL_Type; E : Entity_Id) is
   begin
      Set_Object_Align (LLVM_Value (Obj), GT, E);
   end Set_Object_Align;

   ---------------
   -- Get_Undef --
   ---------------

   function Get_Undef (GT : GL_Type) return GL_Value is
     (G (Get_Undef (Type_Of (GT)), GT));

   -------------------
   -- Get_Undef_Ref --
   -------------------

   function Get_Undef_Ref (GT : GL_Type) return GL_Value is
     (G_Ref (Get_Undef (Create_Access_Type_To (GT)),
             GT, Is_Pristine => True));

   ----------------
   -- Const_Ones --
   ----------------

   function Const_Ones (V : GL_Value) return GL_Value is
     (Const_Ones (Related_Type (V)));

   ----------------
   -- Const_Null --
   ----------------

   function Const_Null (GT : GL_Type) return GL_Value is
     (G (Const_Null (Type_Of (GT)), GT));

   ----------------------
   -- Const_Null_Alloc --
   ----------------------

   function Const_Null_Alloc (GT : GL_Type) return GL_Value is
     (G (Const_Null (Type_For_Relationship
                       (GT, Deref (Relationship_For_Alloc (GT)))),
         GT, Deref (Relationship_For_Alloc (GT))));

   --------------------
   -- Const_Null_Ref --
   --------------------

   function Const_Null_Ref (GT : GL_Type) return GL_Value is
     (G_Ref (Const_Null (Create_Access_Type_To (GT)), GT));

   ----------------
   -- Const_True --
   ----------------

   function Const_True return GL_Value is
     (G (Const_Int (Bit_T, ULL (1), False), Boolean_GL_Type,
         Boolean_Data));

   -----------------
   -- Const_False --
   -----------------

   function Const_False return GL_Value is
     (G (Const_Int (Bit_T, ULL (0), False), Boolean_GL_Type,
         Boolean_Data));

   ---------------
   -- Const_Int --
   ---------------

   function Const_Int (V : GL_Value; N : Uint) return GL_Value is
     (Const_Int (Related_Type (V), N));

   ---------------
   -- Const_Int --
   ---------------

   function Const_Int
     (V : GL_Value; N : ULL; Sign_Extend : Boolean := False) return GL_Value
   is
     (Const_Int (Related_Type (V), N, Sign_Extend));

   ---------------
   -- Const_Int --
   ---------------

   function Const_Int (GT : GL_Type; N : Uint) return GL_Value is
      Result  : constant GL_Value := G (Const_Int (Type_Of (GT), N), GT);
      Val     : constant LLI      := Get_Const_Int_Value (Result);
      Bitsize : constant Integer  :=
        Integer (Get_Scalar_Bit_Size (Type_Of (Result)));

   begin
      --  We're OK if this is a modular type or if the value matches.

      if Is_Modular_Integer_Type (GT) or else UI_From_LLI (Val) = N then
         return Result;

      --  If it's not an unsigned type or this is the full width of ULL,
      --  we've overflowed.

      elsif not Is_Unsigned_Type (GT) or else Bitsize >= ULL'Size then
         return Mark_Overflowed (Result, True);

      end if;

      --  Otherwise, mask off any non-significant bits (that were
      --  sign-extended) and see if we match.

      declare
         Mask   : constant ULL := (ULL (2) ** Bitsize) - 1;
         Masked : constant ULL := Get_Const_Int_Value_ULL (Result) and Mask;

      begin
         return Mark_Overflowed (Result,
                                 UI_From_LLI (LLI (Masked)) /= N);
      end;
   end Const_Int;

   ---------------
   -- Const_Int --
   ---------------

   function Const_Int
     (V           : GL_Value;
      N           : unsigned;
      Sign_Extend : Boolean := False) return GL_Value
   is
     (Const_Int (Related_Type (V), ULL (N), Sign_Extend));

   ---------------
   -- Const_Int --
   ---------------

   function Const_Int
     (GT : GL_Type; N : ULL; Sign_Extend : Boolean := False) return GL_Value
   is
     (G (Const_Int (Type_Of (GT), N, Sign_Extend => Sign_Extend), GT));

   ----------------
   -- Const_Real --
   ----------------

   function Const_Real
     (GT : GL_Type; V : Interfaces.C.double) return GL_Value
   is
     (G (Const_Real (Type_Of (GT), V), GT));

   -----------------
   -- Const_Array --
   -----------------

   function Const_Array
     (Elmts : GL_Value_Array; GT : GL_Type) return GL_Value
   is
      T      : constant Type_T            :=
        (if   Elmts'Length = 0 then Type_Of (Component_Type (GT))
         else Type_Of (Elmts (Elmts'First)));
      --  Take the element type from what was passed, but if no elements
      --  were passed, the only choice is from the component type of the array.
      Values : aliased Access_Value_Array := new Value_Array (Elmts'Range);
      V      : GL_Value;
      procedure Free is new Ada.Unchecked_Deallocation (Value_Array,
                                                        Access_Value_Array);
   begin
      for J in Elmts'Range loop
         Values (J) := LLVM_Value (Elmts (J));
      end loop;

      --  We have a kludge here in the case of making a string literal
      --  that's not in the source (e.g., for a filename) or when
      --  we're handling inner dimensions of a multi-dimensional
      --  array.  In those cases, we use Any_Array for the type, but
      --  that's unconstrained, so we want use relationship "Unknown".

      V := G (Const_Array (T, Values.all'Address, Values.all'Length),
              GT, (if GT = Any_Array_GL_Type then Unknown else Data));
      Free (Values);
      return V;
   end Const_Array;

   ------------------
   -- Const_Struct --
   ------------------

   function Const_Struct
     (Elmts : GL_Value_Array; GT : GL_Type; Packed : Boolean) return GL_Value
   is
      Values : aliased Access_Value_Array := new Value_Array (Elmts'Range);
      V      : GL_Value;
      procedure Free is new Ada.Unchecked_Deallocation (Value_Array,
                                                        Access_Value_Array);
   begin
      for J in Elmts'Range loop
         Values (J) := LLVM_Value (Elmts (J));
      end loop;

      --  We have a kludge here in the case of making a struct that's
      --  not in the source.  In those cases, we pass Any_Array
      --  for the type, so we want use relationship "Unknown".

      V := G (Const_Struct (Values.all'Address, Values.all'Length, Packed),
              GT, (if GT = Any_Array_GL_Type then Unknown else Data));
      Free (Values);
      return V;
   end Const_Struct;

   ----------------------------------
   -- Get_Float_From_Words_And_Exp --
   ---------------------------------

   function Get_Float_From_Words_And_Exp
     (GT : GL_Type; Exp : Int; Words : Word_Array) return GL_Value
   is
      Our_Words : aliased Word_Array := Words;
   begin
      return G (Get_Float_From_Words_And_Exp
                  (Context, Type_Of (GT), Exp, Our_Words'Length,
                   Our_Words (Our_Words'First)'Access),
                GT);
   end Get_Float_From_Words_And_Exp;

   -------------
   -- Pred_FP --
   -------------

   function Pred_FP (V : GL_Value) return GL_Value is
   begin
      return G (Pred_FP (Context, Type_Of (V), LLVM_Value (V)),
                Related_Type (V));
   end Pred_FP;

   ------------------------
   -- Set_Does_Not_Throw --
   ------------------------

   procedure Set_Does_Not_Throw (V : GL_Value) is
   begin
      Set_Does_Not_Throw (LLVM_Value (V));
   end Set_Does_Not_Throw;

   -------------------------
   -- Set_Does_Not_Return --
   -------------------------

   procedure Set_Does_Not_Return (V : GL_Value) is
   begin
      Set_Does_Not_Return (LLVM_Value (V));
   end Set_Does_Not_Return;

   --------------------------
   -- Full_Designated_Type --
   --------------------------

   function Full_Designated_Type (V : GL_Value) return Entity_Id is
     (Full_Designated_Type (Full_Etype (V)));

   --------------------
   -- Full_Base_Type --
   --------------------

   function Full_Base_Type (V : GL_Value) return Entity_Id is
     (Full_Base_Type (Full_Etype (V)));

   ----------------
   -- Add_Clause --
   ----------------

   procedure Add_Clause (V, Exc : GL_Value) is
   begin
      Add_Clause (LLVM_Value (V), LLVM_Value (Exc));
   end Add_Clause;

   -----------------
   -- Set_Cleanup --
   -----------------

   procedure Set_Cleanup (V : GL_Value) is
   begin
      Set_Cleanup (LLVM_Value (V), True);
   end Set_Cleanup;

   -------------------
   -- Get_Type_Size --
   -------------------

   function Get_Type_Size (V : GL_Value) return GL_Value is
     (Get_Type_Size (Related_Type (V), V));

   -------------------
   -- Get_Type_Size --
   -------------------

   function Get_Type_Size (V : GL_Value) return ULL is
     (Get_Type_Size (Type_Of (V)));

   -------------------------
   -- Get_Scalar_Bit_Size --
   -------------------------

   function Get_Scalar_Bit_Size (V : GL_Value) return ULL is
     (Get_Scalar_Bit_Size (Type_Of (Related_Type (V))));

   ------------------------
   -- Get_Type_Alignment --
   ------------------------

   function Get_Type_Alignment
     (V : GL_Value; Use_Specified : Boolean := True) return Nat
   is
     (Get_Type_Alignment (Related_Type (V), Use_Specified => Use_Specified));

   ------------------------
   -- Get_Type_Alignment --
   ------------------------

   function Get_Type_Alignment
     (GT : GL_Type; Use_Specified : Boolean := True) return GL_Value
   is
     (Size_Const_Int (Get_Type_Alignment (GT,
                                          Use_Specified => Use_Specified)));

   ----------------
   -- Add_Global --
   ----------------

   function Add_Global
     (GT             : GL_Type;
      Name           : String;
      Need_Reference : Boolean := False) return GL_Value
   is
      R : GL_Relationship := Relationship_For_Alloc (GT);

   begin
      --  The type we pass to Add_Global is the type of the actual data, but
      --  since the global value in LLVM is a pointer, the relationship is
      --  the reference.  So we compute the reference we want and then make the
      --  type corresponding to a data of that reference.  But first handle
      --  the case where we need an indirection (because of an address clause
      --  or a dynamically-sized object).  In that case, if we would normally
      --  have a pointer to the bounds and data, we actually store the thin
      --  pointer (which points in the middle).

      if Need_Reference then
         R := Ref (if   R = Reference_To_Bounds_And_Data
                   then Thin_Pointer else R);
      end if;

      return G (Add_Global (Module, Type_For_Relationship (GT, Deref (R)),
                            Name),
                GT, R);
   end Add_Global;

   --------------------
   -- Set_Value_Name --
   --------------------

   procedure Set_Value_Name (V : GL_Value; Name : String) is
   begin
      Set_Value_Name (LLVM_Value (V), Name);
   end Set_Value_Name;

   ------------------------
   -- Add_Cold_Attribute --
   -----------------------

   procedure Add_Cold_Attribute (V : GL_Value) is
   begin
      Add_Cold_Attribute (LLVM_Value (V));
   end Add_Cold_Attribute;

   -----------------------------------
   -- Add_Dereferenceable_Attribute --
   ----------------------------------

   procedure Add_Dereferenceable_Attribute
     (V : GL_Value; Idx : Integer; GT : GL_Type)
   is
      T : constant Type_T := Type_Of (GT);

   begin
      --  We can only show this is dereferencable if we know its size.
      --  But this implies non-null, so we can set that even if we don't
      --  know the size.

      if Type_Is_Sized (T) then
         Add_Dereferenceable_Attribute (LLVM_Value (V), unsigned (Idx),
                                        To_Bytes (Get_Type_Size (T)));
      else
         Add_Non_Null_Attribute (LLVM_Value (V), unsigned (Idx));
      end if;
   end Add_Dereferenceable_Attribute;

   -----------------------------------
   -- Add_Dereferenceable_Attribute --
   ----------------------------------

   procedure Add_Dereferenceable_Attribute (V : GL_Value; GT : GL_Type)
   is
      T : constant Type_T := Type_Of (GT);

   begin
      --  We can only show this is dereferencable if we know its size.
      --  But this implies non-null, so we can set that even if we don't
      --  know the size.

      if Type_Is_Sized (T) then
         Add_Dereferenceable_Attribute (LLVM_Value (V),
                                        To_Bytes (Get_Type_Size (T)));
      else
         Add_Non_Null_Attribute (LLVM_Value (V));
      end if;
   end Add_Dereferenceable_Attribute;

   -------------------------------------------
   -- Add_Dereferenceable_Or_Null_Attribute --
   -------------------------------------------

   procedure Add_Dereferenceable_Or_Null_Attribute
     (V : GL_Value; Idx : Integer; GT : GL_Type)
   is
      T : constant Type_T := Type_Of (GT);

   begin
      if Type_Is_Sized (T) then
         Add_Dereferenceable_Or_Null_Attribute (LLVM_Value (V), unsigned (Idx),
                                                To_Bytes (Get_Type_Size (T)));
      end if;
   end Add_Dereferenceable_Or_Null_Attribute;

   -------------------------------------------
   -- Add_Dereferenceable_Or_Null_Attribute --
   -------------------------------------------

   procedure Add_Dereferenceable_Or_Null_Attribute (V : GL_Value; GT : GL_Type)
   is
      T : constant Type_T := Type_Of (GT);

   begin
      if Type_Is_Sized (T) then
         Add_Dereferenceable_Or_Null_Attribute (LLVM_Value (V),
                                                To_Bytes (Get_Type_Size (T)));
      end if;
   end Add_Dereferenceable_Or_Null_Attribute;

   --------------------------
   -- Add_Inline_Attribute --
   --------------------------

   procedure Add_Inline_Attribute (V : GL_Value; Subp : Entity_Id) is
   begin
      if Is_Inlined (Subp) and then Has_Pragma_Inline_Always (Subp) then
         Add_Inline_Always_Attribute (LLVM_Value (V));
      elsif Is_Inlined (Subp) and then Has_Pragma_Inline (Subp) then
         Add_Inline_Hint_Attribute (LLVM_Value (V));
      elsif Has_Pragma_No_Inline (Subp) then
         Add_Inline_No_Attribute (LLVM_Value (V));
      end if;
   end Add_Inline_Attribute;

   ------------------------
   -- Add_Nest_Attribute --
   -----------------------

   procedure Add_Nest_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Nest_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Nest_Attribute;

   ---------------------------
   -- Add_Noalias_Attribute --
   ---------------------------

   procedure Add_Noalias_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Noalias_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Noalias_Attribute;

   ---------------------------
   -- Add_Noalias_Attribute --
   ---------------------------

   procedure Add_Noalias_Attribute (V : GL_Value) is
   begin
      Add_Noalias_Attribute (LLVM_Value (V));
   end Add_Noalias_Attribute;

   ---------------------------
   -- Add_Nocapture_Attribute --
   ---------------------------

   procedure Add_Nocapture_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Nocapture_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Nocapture_Attribute;

   ----------------------------
   -- Add_Non_Null_Attribute --
   ----------------------------

   procedure Add_Non_Null_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Non_Null_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Non_Null_Attribute;

   ----------------------------
   -- Add_Non_Null_Attribute --
   ----------------------------

   procedure Add_Non_Null_Attribute (V : GL_Value) is
   begin
      Add_Non_Null_Attribute (LLVM_Value (V));
   end Add_Non_Null_Attribute;

   ----------------------------
   -- Add_Readonly_Attribute --
   ----------------------------

   procedure Add_Readonly_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Readonly_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Readonly_Attribute;

   -----------------------------
   -- Add_Writeonly_Attribute --
   -----------------------------

   procedure Add_Writeonly_Attribute (V : GL_Value; Idx : Integer) is
   begin
      Add_Writeonly_Attribute (LLVM_Value (V), unsigned (Idx));
   end Add_Writeonly_Attribute;

   -------------------
   -- Set_DSO_Local --
   -------------------

   procedure Set_DSO_Local (V : GL_Value) is
   begin
      Set_DSO_Local (LLVM_Value (V));
   end Set_DSO_Local;

   ---------------------
   -- Set_Initializer --
   ---------------------

   procedure Set_Initializer (V, Expr : GL_Value) is
      VV : Value_T := LLVM_Value (V);
      VE : Value_T := LLVM_Value (Expr);

   begin
      --  If VV is a conversion, its operand is the actual value and we
      --  know that VE's type is a structure that we can convert to it.
      --  See Can_Initialize in GNATLLVM.Variables.

      if Get_Value_Kind (VV) = Constant_Expr_Value_Kind then
         VV := Get_Operand (VV, 0);
         VE := Convert_Aggregate_Constant (VE,
                                           Get_Element_Type (Type_Of (VV)));
      end if;

      Set_Initializer (VV, VE);
      if Get_Linkage (VV) = External_Weak_Linkage then
         Set_Linkage (VV, Weak_Any_Linkage);
      end if;
   end Set_Initializer;

   -----------------
   -- Set_Linkage --
   -----------------

   procedure Set_Linkage (V : GL_Value; Linkage : Linkage_T) is
   begin
      Set_Linkage (LLVM_Value (V), Linkage);
   end Set_Linkage;

   -------------------------
   -- Set_Global_Constant --
   -------------------------

   procedure Set_Global_Constant (V : GL_Value; B : Boolean := True) is
      VV : Value_T := LLVM_Value (V);
   begin

      --  If VV is a conversion, its operand is the actual variable

      if Get_Value_Kind (VV) = Constant_Expr_Value_Kind then
         VV := Get_Operand (VV, 0);
      end if;

      if Present (Is_A_Global_Variable (VV)) then
         Set_Global_Constant (VV, B);
      end if;
   end Set_Global_Constant;

   ----------------------
   -- Set_Thread_Local --
   ----------------------

   procedure Set_Thread_Local (V : GL_Value; Thread_Local : Boolean := True) is
   begin
      Set_Thread_Local (LLVM_Value (V), Thread_Local);
   end Set_Thread_Local;

   -----------------
   -- Set_Section --
   -----------------

   procedure Set_Section (V : GL_Value; S : String) is
   begin
      Set_Section (LLVM_Value (V), S);
   end Set_Section;

   ----------------------
   -- Set_Unnamed_Addr --
   ----------------------

   procedure Set_Unnamed_Addr
     (V : GL_Value; Has_Unnamed_Addr : Boolean := True) is
   begin
      Set_Unnamed_Addr (LLVM_Value (V), Has_Unnamed_Addr);
   end Set_Unnamed_Addr;

   -----------------------------
   -- Set_Volatile_For_Atomic --
   -----------------------------

   procedure Set_Volatile_For_Atomic (V : GL_Value) is
   begin
      Set_Volatile_For_Atomic (LLVM_Value (V));
   end Set_Volatile_For_Atomic;

   ---------------------
   -- Set_Arith_Attrs --
   ---------------------

   function Set_Arith_Attrs (Inst : Value_T; V : GL_Value) return Value_T is
   begin
      --  Before trying to set attributes, we need to verify that this is
      --  an instruction.  If so, set the flags according to the type.
      --  We have to treat a pointer as unsigned here, since it's possible
      --  that it might cross the boundary where the high-bit changes.
      --  A modular type is defined to wrap.  Biased type are unsigned.

      if No (Is_A_Instruction (Inst)) or else Is_Modular_Integer_Type (V) then
         null;
      elsif Is_Access_Type (V) or else Is_Unsigned_Type (V) then
         Set_NUW (Inst);
      else
         Set_NSW (Inst);
      end if;

      return Inst;
   end Set_Arith_Attrs;

   --------------------
   -- Set_Subprogram --
   --------------------

   procedure Set_Subprogram (V : GL_Value; M : Metadata_T) is
   begin
      Set_Subprogram (LLVM_Value (V), M);
   end Set_Subprogram;

   -------------------------
   -- Is_Layout_Identical --
   -------------------------

   function Is_Layout_Identical (V : GL_Value; GT : GL_Type) return Boolean is
     (Is_Layout_Identical (Type_Of (V), Type_Of (GT)));

   -------------------------
   -- Is_Layout_Identical --
   -------------------------

   function Is_Layout_Identical (GT1, GT2 : GL_Type) return Boolean is
     (Is_Layout_Identical (Type_Of (GT1), Type_Of (GT2)));

   -----------------------------
   -- Convert_Struct_Constant --
   -----------------------------

   function Convert_Struct_Constant
     (V : GL_Value; GT : GL_Type) return GL_Value
   is
      T   : constant Type_T  := Type_Of (GT);
      Val : constant Value_T := LLVM_Value (V);

   begin
      return G ((if   Is_Null (Val) then Const_Null (T)
                 else Convert_Struct_Constant (Val, T)),
                GT, Data);
   end Convert_Struct_Constant;

   -----------------------------
   -- Convert_Struct_Constant --
   -----------------------------

   function Convert_Struct_Constant (V : Value_T; T : Type_T) return Value_T
   is
      Num_Elmts : constant Nat    := Nat (Count_Struct_Element_Types (T));
      Values    : aliased Value_Array (0 .. Num_Elmts - 1);

   begin
      for J in Values'Range loop
         declare
            Idx   : constant unsigned := unsigned (J);
            In_V  : Value_T           := Get_Operand (V, Idx);
            In_T  : constant Type_T   := Type_Of (In_V);
            Out_T : constant Type_T   := Struct_Get_Type_At_Index (T, Idx);

         begin
            --  It's possible that we have two identical constants but
            --  the inner types are also the same structure but different
            --  named types.  So we have to make a recursive call.

            if In_T /= Out_T
              and then Get_Type_Kind (In_T) = Struct_Type_Kind
            then
               In_V := Convert_Struct_Constant (In_V, Out_T);
            end if;

            Values (J) := In_V;
         end;
      end loop;

      return Const_Named_Struct (T, Values'Address, unsigned (Num_Elmts));

   end Convert_Struct_Constant;

   -------------------------
   -- Idxs_From_GL_Values --
   -------------------------

   function Idxs_From_GL_Values (Idxs : GL_Value_Array) return Index_Array is
      Bound  : LLI;

   begin
      return C_Idxs : Index_Array (Idxs'Range) do
         for J in Idxs'Range loop
            Bound := Get_Const_Int_Value (Idxs (J));

            --  Since this is an LLVM object, we know that all valid bounds
            --  are within the range of unsigned.  But we don't want to get
            --  a constraint error below if the constant is invalid.  So
            --  test and force to zero (any constant will do since this is
            --  erroneous) in that case.

            if Bound < 0 or else Bound > LLI (unsigned'Last) then
               Bound := 0;
            end if;

            C_Idxs (J) := unsigned (Bound);
         end loop;
      end return;
   end Idxs_From_GL_Values;

   ---------------------
   -- Get_Alloca_Name --
   ---------------------

   function Get_Alloca_Name
     (Def_Ident : Entity_Id; Name : String) return String
   is
     (if    Name = "%%" then "" elsif Name /= "" then Name
      elsif Present (Def_Ident)
      then  Get_Ext_Name (Def_Ident) else "");

   ----------------------
   -- Error_Msg_NE_Num --
   ----------------------

   procedure Error_Msg_NE_Num
     (Msg : String; N : Node_Id; E : Entity_Id; V : GL_Value) is
   begin
      Error_Msg_NE_Num (Msg, N, E, UI_From_GL_Value (V));
   end Error_Msg_NE_Num;

   pragma Annotate (Xcov, Exempt_On, "Debug helpers");

   -------------------
   -- Dump_GL_Value --
   -------------------

   procedure Dump_GL_Value (V : GL_Value) is
   begin
      if No (V) then
         Write_Line ("None");
         return;
      end if;

      Dump_LLVM_Value (V.Value);
      Dump_LLVM_Type (Type_Of (V.Value));
      if Is_Pristine (V) then
         Write_Str ("Pristine ");
      end if;
      if Is_Volatile (V) then
         Write_Str ("Volatile ");
      end if;
      if Is_Atomic (V) then
         Write_Str ("Atomic ");
      end if;
      if Overflowed (V) then
         Write_Str ("Overflowed ");
      end if;
      Write_Str (GL_Relationship'Image (V.Relationship) & "(");
      Dump_GL_Type_Int (V.Typ, False);
      Write_Str ("): ");
      pg (Union_Id (Full_Etype (V.Typ)));
   end Dump_GL_Value;

   pragma Annotate (Xcov, Exempt_Off, "Debug helpers");

end GNATLLVM.GLValue;
