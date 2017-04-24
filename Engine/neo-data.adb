
--                                                                                                                                      --
--                                                         N E O  E N G I N E                                                           --
--                                                                                                                                      --
--                                                 Copyright (C) 2016 Justin Squirek                                                    --
--                                                                                                                                      --
-- Neo is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the --
-- Free Software Foundation, either version 3 of the License, or (at your option) any later version.                                    --
--                                                                                                                                      --
-- Neo is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of                --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.                            --
--                                                                                                                                      --
-- You should have received a copy of the GNU General Public License along with Neo. If not, see gnu.org/licenses                       --
--                                                                                                                                      --

package body Neo.Data is

  -------------
  -- Handler --
  -------------

  package body Handler is
    Unsupported, Duplicate_Format : Exception;

    -- Internal format for relating extensions to callbacks
    type Format_State is record
        Load       : not null access function (Path : Str) return T;
        Extensions : Str_Unbound;
      end record;
    package Ordered_Format is new Ordered (Format_T, Format_State);
    Formats : Ordered_Format.Safe_Map;

    -- Dispatch to a stored callback based on the extension of the path
    function Load (Path : Str) return T is 
      Ext_Val : Str := Path (Index (Path, ".", Backward) + 1..Path'Last);
      begin
        Put_Line (Ext_Val);
        for Format of Formats.Get loop
          for Extension of Split (To_Str (Format.Extensions), ",") loop
            Put_Line (S (Extension));
            if Extension = Ext_Val then return Format.Load (Path); end if;
          end loop;
        end loop;
        raise Unsupported;
      end;

    -- Package for registering format callbacks
    package body Format is
        function Informal_Load (Path : Str) return T renames Format.Load;

        -- Controller
        type Control_State is new Controlled with null record;
        procedure Finalize   (Control : in out Control_State);
        procedure Initialize (Control : in out Control_State);
        procedure Finalize   (Control : in out Control_State) is begin Formats.Delete (Kind); end;
        procedure Initialize (Control : in out Control_State) is
          begin
            if Formats.Has (Kind) then raise Duplicate_Format; end if;
            Formats.Insert (Kind, (Informal_Load'Access, To_Str_Unbound (To_Lower (Extensions))));
          end;
        Controller : Control_State;
      end;
  end;

  ------------
  -- Parser --
  ------------

  package body Parser is
    Invalid : Exception;

    ----------
    -- Load --
    ----------

    -- Load file and pre-process text (possibly remove comments and replace tabs)
    function Load return Array_Str_Unbound is
      SINGLELINE_REMOVE    : Bool    := Comment         /= NULL_STR;
      MULTILINE_REMOVE     : Bool    := Comment_Start   /= NULL_STR;
      TAB_REPLACEMENT      : Bool    := Tab_Replacement /= NULL_CHAR_16;
      In_Multiline_Comment : Bool    := False;
      Comment_Start_Index  : Natural := 0;
      Comment_End_Index    : Natural := 0;
      Comment_Index        : Natural := 0;
      Tab_Index            : Natural := 0;
      Data                 : File_Type;
      This                 : Vector_Str_16_Unbound.Unsafe.Vector;
      begin

        -- Verify generic package foramls
        Assert (Comment_Start'Length = Trim (Comment_Start, Both)'Length);
        Assert (Comment_End'Length   = Trim (Comment_End,   Both)'Length);
        Assert (Comment'Length       = Trim (Comment,       Both)'Length);
        Assert ((if MULTILINE_REMOVE then Comment_End /= NULL_STR else Comment_End /= NULL_STR));

        -- Open the file
        Open (Data, In_File, To_Str_8 (Path)); -- Must be Str_8 ???

        -- Perform first pass
        while not End_Of_File (Data) loop
          Current := To_Str_Unbound (Get_Line (Data));

          -- Remove comments
          if SINGLELINE_REMOVE or MULTILINE_REMOVE then
            if MULTILINE_REMOVE then Comment_Start_Index := 0; end if;
            loop

              -- Multi-line comment removal
              if In_Multiline_Comment then
                Comment_End_Index := Index (Current, Comment_End);

                -- No end in sight
                if Comment_End_Index = 0 then
                  if Comment_Start_Index = 0 then Current := NULL_STR_UNBOUND; end if;
                  exit;
                end if;

                -- Delete comment
                In_Multiline_Comment := False;
                Delete (Current, Comment_Start_Index, Comment_End_Index + Comment_End'Length);

              -- Single-line comment removal
              else
                if SINGLELINE_REMOVE then Comment_Index       := Index (Current, Comment);       end if;
                if MULTILINE_REMOVE  then Comment_Start_Index := Index (Current, Comment_Start); end if;
                exit when Comment_Index = 0 and Comment_Start_Index = 0;

                -- Delete comment
                if SINGLELINE_REMOVE and then Comment_Index > 0 and (Comment_Index < Multi_Index or Multi_Index = 0) then
                  Head (Current, Index (Current, Comment_Index) - 1);
                  exit;

                -- Flag multi-line comment
                else In_Multiline_Comment := True; end if;
              end if;
            end loop;
          end if;

          -- Remove tabs
          if TAB_REPLACEMENT then
            loop
              Tab_Index := Index (Current, TAB_16);
              exit when Tab_Index = 0;
              Overwrite (Current, Tab_Index, " "));
            end loop;
          end if;

          -- Add the current line to the internal buffer
          if Current /= NULL_STR_UNBOUND then This.Append (Current); end if;
        end loop;

        -- Close the file
        Close (Data);
        return Vector_Str_16_Unbound.To_Unsafe_Array (This);
      end;

    -------------
    -- Globals --
    -------------

    This    : Array_Str_Unbound := Load; -- Cause the loading of data to be performed at package instantiation
    Row     : Positive          := 1;
    Column  : Positive          := 1;

    -------------
    -- Parsing --
    -------------

    -- Internal procedure for skipping whitespace
    procedure Seek is
      begin
        Column := Column + 1;
        while not At_EOF loop
          loop
            if Column > Length (This (Row)) or else This (Row) = NULL_STR_UNBOUND then
              Column := 1;
              Row    := Row + 1;
              exit;
            end if;
            if Index (Slice (This (Row), Column, Length (This (Row))), "" & Separator) /= Column then return; end if;
            Column := Column + 1;
          end loop;
        end loop;
      end;

    -- Position
    function At_EOF return Bool is ((if Row > This'Last then True else False));
    function At_EOL return Bool is
      Previous_Column : Positive    := Column;
      Previous_Row    : Positive    := Row;
      Result          : Str_Unbound := Next;
      begin
        Column          := Previous_Column;
        Previous_Column := Row;
        Row             := Previous_Row;
        return Previous_Column /= Row;
      end;

    -- Skip
    procedure Skip_Set (Starting, Ending : Str) is Junk : Str_Unbound := Next_Set (Starting, Ending); begin null; end;
    procedure Skip_Set (Ending : Str) is begin Skip_Set ("" & Element (This (Row), Column), Ending); end;
    procedure Skip_Line is begin Row := Row + 1; Column := 1; end;
    procedure Skip (Amount : Positive := 1) is
      Junk : Str_Unbound;
      begin
        for I in 1..Amount loop Junk := Next; end loop;
      end;

    -- Skip until.. this could stand a cleaning
    procedure Skip_Until (Text               : Str; Fail_On_EOF : Bool := False) is begin Skip_Until ((1 => U (Text)),                          Fail_On_EOF); end;
    procedure Skip_Until (T1, T2             : Str; Fail_On_EOF : Bool := False) is begin Skip_Until ((U (T1), U (T2)),                         Fail_On_EOF); end;
    procedure Skip_Until (T1, T2, T3         : Str; Fail_On_EOF : Bool := False) is begin Skip_Until ((U (T1), U (T2), U (T3)),                 Fail_On_EOF); end;
    procedure Skip_Until (T1, T2, T3, T4     : Str; Fail_On_EOF : Bool := False) is begin Skip_Until ((U (T1), U (T2), U (T3), U (T4)),         Fail_On_EOF); end;
    procedure Skip_Until (T1, T2, T3, T4, T5 : Str; Fail_On_EOF : Bool := False) is begin Skip_Until ((U (T1), U (T2), U (T3), U (T4), U (T5)), Fail_On_EOF); end;
    procedure Skip_Until (T : Array_Str_Unbound; Fail_On_EOF : Bool := False) is
      Start_Column : Positive := Column;
      Start_Row    : Positive := Row;
      begin
        while not At_EOF loop
          for I of T loop
            if S (I) = Peek then return; end if;
          end loop;
        end loop;
        if Fail_On_EOF then raise Invalid; end if;
        Column := Start_Column;
        Row    := Start_Row;
      end;

    -- Assert
    procedure Assert (T1, T2             : Str) is begin Assert (T1);             Assert (T2); end;
    procedure Assert (T1, T2, T3         : Str) is begin Assert (T1, T2);         Assert (T3); end;
    procedure Assert (T1, T2, T3, T4     : Str) is begin Assert (T1, T2, T3);     Assert (T4); end;
    procedure Assert (T1, T2, T3, T4, T5 : Str) is begin Assert (T1, T2, T3, T4); Assert (T5); end;
    procedure Assert (Text : Str) is
      begin
        if Index (Slice (This (Row), Column, Length (This (Row))), Text) /= Column then raise Invalid; end if;
        Column := Column + Text'length - 1;
        Seek;
      end;

    -- Check ahead without advancing
    function Peek_U return Str_Unbound is
      Previous_Column : Positive    := Column;
      Previous_Row    : Positive    := Row;
      Result          : Str_Unbound := Next;
      begin
        Row    := Previous_Row;
        Column := Previous_Column;
        return Result;
      end;

    -- Next number
    function Next_Internal return Real_64 is
      Found_Decimal : Bool := False;
      Found_Digit   : Bool := False;
      Found_Sign    : Bool := False;
      Result        : Str_Unbound;
      begin
        while Column <= Length (This (Row)) loop
          if not Is_Digit (Element (This (Row), Column)) then
            case Element (This (Row), Column) is
              when '-' | '+' => exit when Found_Digit or Found_Sign;
                                Found_Sign := True;                    
              when '.' =>       exit when Found_Decimal;
                                Found_Digit   := True;
                                Found_Decimal := True;
              when others =>    exit;
            end case;
          elsif not Found_Digit then Found_Digit := True; end if;
          Result := Result & Element (This (Row), Column);
          Column := Column + 1;
        end loop;
        if Result = NULL_STR_UNBOUND then raise Invalid; end if;
        Seek;
        return Real_64'Wide_Value (To_Str (Result));
      end;
    function Next return Real_64         renames Next_Internal;
    function Next return Real            is (Real            (Next_Internal));
    function Next return Byte            is (Byte            (Next_Internal));
    function Next return Int             is (Int             (Next_Internal));
    function Next return Int_32_Unsigned is (Int_32_Unsigned (Next_Internal));
    function Next return Int_64          is (Int_64          (Next_Internal));
    function Next return Int_64_Unsigned is (Int_64_Unsigned (Next_Internal));

    -- Next string
    function Next_Line return Str_Unbound is
      Result : Str_Unbound := To_Str_Unbound (Slice (This (Row), Column, Length (This (Row))));
      begin
        Parser.Skip_Line;
        return Result;
      end;
    function Next return Str_Unbound is
      Result : Str_Unbound := To_Str_Unbound (Slice (This (Row), Column, Length (This (Row))));
      I      : Natural     := Index (Result, "" & Separator);
      begin
        if I /= 0 then Delete (Result, I, Length (Result)); end if;
        Column := Column + Length (Result);
        Seek;
        return Result;
      end;

    -- Next delimited group or set
    function Next_Set (Ending : Str) return Str_Unbound is (Next_Set ("" & Element (This (Row), Column), Ending));
    function Next_Set (Starting, Ending : Str) return Str_Unbound is
      Result : Str_Unbound;
      Buffer : Str_Unbound;
      I      : Natural;
      begin
        Assert (Starting);
        while not At_EOF loop
          Buffer := To_Str_Unbound (Slice (This (Row), Column, Length (This (Row))));
          I      := Index (Buffer, Ending);
          if I = 0 then
            Column := 1;
            Row    := Row + 1;
            Result := Result & Buffer & EOL;
          else
            Buffer := Delete (Buffer, I, Length (Buffer));
            Column := Column + Length (Buffer) + Ending'length;
            Seek;
            return Result & Buffer;
          end if;
        end loop;
        raise Invalid;
      end;
  end;
end;