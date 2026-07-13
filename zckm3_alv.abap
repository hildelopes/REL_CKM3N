*&---------------------------------------------------------------------*
*& Report  ZCKM3_ALV
*&---------------------------------------------------------------------*
*& Estratificação por elemento de custo (visão CKM3N) em ALV,
*& multi-material / multi-lote, a partir do split de preço do
*& Material Ledger.
*&
*& Fonte de dados : MLCCS_READ_PR (resolve CKMLKEPH / CKMLPRKEKO)
*& Textos         : TCKH1 (textos dos elementos do esquema ELEHK)
*& Preço/unidade  : CKMLCR (PEINH / preços por tipo de moeda)
*& Materiais      : CKMLHD + MARA + MAKT
*&
*& Saída: uma linha por Material x Elemento de custo, com colunas
*&        Total / Fixo / Variável, subtotal por material.
*&
*& Obs.: valores exibidos por unidade de preço (PEINH) do CKMLCR,
*&       mesmo referencial da CKM3N quando Qtd.ref = unidade de preço.
*&---------------------------------------------------------------------*
REPORT zckm3_alv.

TABLES: mara, ckmlhd.

*----------------------------------------------------------------------*
* Tipos
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_mat,
         kalnr TYPE ckmlhd-kalnr,
         matnr TYPE matnr,
         bwkey TYPE bwkey,
         bwtar TYPE bwtar_d,
         maktx TYPE maktx,
         meins TYPE meins,
       END OF ty_mat.

TYPES: BEGIN OF ty_out,
         matnr TYPE matnr,
         maktx TYPE maktx,
         bwtar TYPE bwtar_d,
         elemt TYPE tckh1-elemt,
         txele TYPE tckh1-txele,
         total TYPE ckmlkeph-kst001,
         fixo  TYPE ckmlkeph-kst001,
         varia TYPE ckmlkeph-kst001,
         waers TYPE waers,
         peinh TYPE peinh,
         meins TYPE meins,
       END OF ty_out.

*----------------------------------------------------------------------*
* Tela de seleção
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS:     p_werks TYPE werks_d OBLIGATORY MEMORY ID wrk.
  SELECT-OPTIONS: s_matnr FOR mara-matnr,
                  s_bwtar FOR ckmlhd-bwtar.
  PARAMETERS:     p_bdatj TYPE bdatj OBLIGATORY,
                  p_poper TYPE poper OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
  PARAMETERS: p_curtp TYPE curtp   DEFAULT '10',   " 10=moeda empresa
              p_prtyp TYPE c LENGTH 1 DEFAULT 'V', " V=periódico S=standard
              p_elehk TYPE tckh1-elehk DEFAULT '01', " esquema de elementos
              p_zeros AS CHECKBOX DEFAULT abap_false. " exibir elem. zerados
SELECTION-SCREEN END OF BLOCK b2.

INITIALIZATION.
  p_bdatj = sy-datum(4).
  p_poper = sy-datum+4(2).

*----------------------------------------------------------------------*
* Classe principal
*----------------------------------------------------------------------*
CLASS lcl_report DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.
    DATA: mt_mat    TYPE STANDARD TABLE OF ty_mat,
          mt_out    TYPE STANDARD TABLE OF ty_out,
          mt_prkeph TYPE STANDARD TABLE OF ckmlprkeph,
          mt_txele  TYPE HASHED TABLE OF tckh1
                         WITH UNIQUE KEY elehk elemt,
          mv_waers  TYPE waers.

    METHODS: seleciona_materiais,
             le_split_ml,
             monta_saida,
             exibe_alv.
ENDCLASS.

CLASS lcl_report IMPLEMENTATION.

  METHOD run.
    seleciona_materiais( ).
    IF mt_mat IS INITIAL.
      MESSAGE 'Nenhum material encontrado para os filtros informados'(m01)
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    le_split_ml( ).
    monta_saida( ).
    IF mt_out IS INITIAL.
      MESSAGE 'Sem split de custo (CKMLKEPH) para o período/tipo de preço'(m02)
        TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    exibe_alv( ).
  ENDMETHOD.

  METHOD seleciona_materiais.

    " Materiais com número de cálculo de custo (ML) no centro
    SELECT h~kalnr, h~matnr, h~bwkey, h~bwtar,
           t~maktx, m~meins
      FROM ckmlhd AS h
      INNER JOIN mara AS m ON m~matnr = h~matnr
      LEFT  JOIN makt AS t ON t~matnr = h~matnr
                          AND t~spras = @sy-langu
      WHERE h~bwkey =  @p_werks
        AND h~matnr IN @s_matnr
        AND h~bwtar IN @s_bwtar
      INTO TABLE @mt_mat.

    " Moeda da empresa (para CURTP 10). Para outros CURTP ajustar
    " a determinação da moeda conforme necessário (TCURM / T001A).
    SELECT SINGLE c~waers
      FROM t001w AS w
      INNER JOIN t001k AS k ON k~bwkey = w~bwkey
      INNER JOIN t001  AS c ON c~bukrs = k~bukrs
      WHERE w~werks = @p_werks
      INTO @mv_waers.

    " Textos dos elementos de custo do esquema
    SELECT * FROM tckh1
      WHERE spras = @sy-langu
        AND elehk = @p_elehk
      INTO TABLE @mt_txele.

  ENDMETHOD.

  METHOD le_split_ml.

    DATA: lt_inkeph TYPE STANDARD TABLE OF ckmlprkeph,
          lt_prkeko TYPE STANDARD TABLE OF ckmlprkeko.

    " Chaves de leitura: 1 entrada por número de cálculo/período
    LOOP AT mt_mat ASSIGNING FIELD-SYMBOL(<ls_mat>).
      APPEND INITIAL LINE TO lt_inkeph ASSIGNING FIELD-SYMBOL(<ls_key>).
      <ls_key>-kalnr  = <ls_mat>-kalnr.
      <ls_key>-bdatj  = p_bdatj.
      <ls_key>-poper  = p_poper.
      <ls_key>-untper = '000'.
      <ls_key>-curtp  = p_curtp.
    ENDLOOP.

    " Leitura oficial do split de preço do Material Ledger.
    " Retorna as linhas de CKMLKEPH já resolvidas (total e parte fixa).
    CALL FUNCTION 'MLCCS_READ_PR'
      EXPORTING
        i_use_buffer    = abap_false
      TABLES
        it_inkeph       = lt_inkeph
        ot_prkeko       = lt_prkeko
        ot_prkeph       = mt_prkeph
      EXCEPTIONS
        no_prices_found = 1
        OTHERS          = 2.

    IF sy-subrc <> 0.
      CLEAR mt_prkeph.
    ENDIF.

  ENDMETHOD.

  METHOD monta_saida.

    DATA: ls_out   TYPE ty_out,
          lv_field TYPE fieldname.

    FIELD-SYMBOLS: <lv_val> TYPE any.

    " Preço unitário (PEINH) do período, por tipo de moeda
    SELECT kalnr, peinh
      FROM ckmlcr
      FOR ALL ENTRIES IN @mt_mat
      WHERE kalnr = @mt_mat-kalnr
        AND bdatj = @p_bdatj
        AND poper = @p_poper
        AND curtp = @p_curtp
      INTO TABLE @DATA(lt_cr).

    SORT lt_cr BY kalnr.

    LOOP AT mt_mat ASSIGNING FIELD-SYMBOL(<ls_mat>).

      " Linha de totais (KKZST = ' ') e de custos fixos (KKZST = 'X')
      " do tipo de preço solicitado
      READ TABLE mt_prkeph ASSIGNING FIELD-SYMBOL(<ls_tot>)
           WITH KEY kalnr = <ls_mat>-kalnr
                    prtyp = p_prtyp
                    kkzst = space.
      CHECK sy-subrc = 0.

      READ TABLE mt_prkeph ASSIGNING FIELD-SYMBOL(<ls_fix>)
           WITH KEY kalnr = <ls_mat>-kalnr
                    prtyp = p_prtyp
                    kkzst = 'X'.
      DATA(lv_tem_fixo) = xsdbool( sy-subrc = 0 ).

      READ TABLE lt_cr INTO DATA(ls_cr)
           WITH KEY kalnr = <ls_mat>-kalnr BINARY SEARCH.
      IF sy-subrc <> 0.
        CLEAR ls_cr.
      ENDIF.

      " Percorre os 40 campos de elemento (KST001..KST040)
      DO 40 TIMES.

        CLEAR ls_out.
        ls_out-elemt = sy-index.
        lv_field = |KST{ sy-index WIDTH = 3 PAD = '0' ALIGN = RIGHT }|.

        ASSIGN COMPONENT lv_field OF STRUCTURE <ls_tot> TO <lv_val>.
        CHECK sy-subrc = 0.
        ls_out-total = <lv_val>.

        IF lv_tem_fixo = abap_true.
          ASSIGN COMPONENT lv_field OF STRUCTURE <ls_fix> TO <lv_val>.
          IF sy-subrc = 0.
            ls_out-fixo = <lv_val>.
          ENDIF.
        ENDIF.

        ls_out-varia = ls_out-total - ls_out-fixo.

        " Suprime elementos sem texto no esquema E sem valor
        READ TABLE mt_txele ASSIGNING FIELD-SYMBOL(<ls_txt>)
             WITH TABLE KEY elehk = p_elehk
                            elemt = ls_out-elemt.
        IF sy-subrc = 0.
          ls_out-txele = <ls_txt>-txele.
        ELSEIF ls_out-total = 0.
          CONTINUE.
        ENDIF.

        IF p_zeros = abap_false AND
           ls_out-total = 0 AND ls_out-fixo = 0.
          CONTINUE.
        ENDIF.

        ls_out-matnr = <ls_mat>-matnr.
        ls_out-maktx = <ls_mat>-maktx.
        ls_out-bwtar = <ls_mat>-bwtar.
        ls_out-meins = <ls_mat>-meins.
        ls_out-peinh = ls_cr-peinh.
        ls_out-waers = mv_waers.

        APPEND ls_out TO mt_out.

      ENDDO.

    ENDLOOP.

    SORT mt_out BY matnr bwtar elemt.

  ENDMETHOD.

  METHOD exibe_alv.

    DATA: lo_salv TYPE REF TO cl_salv_table.

    TRY.
        cl_salv_table=>factory(
          IMPORTING r_salv_table = lo_salv
          CHANGING  t_table      = mt_out ).

        lo_salv->get_functions( )->set_all( abap_true ).
        lo_salv->get_display_settings( )->set_striped_pattern( abap_true ).
        lo_salv->get_display_settings( )->set_list_header(
          |Estratificação de custo ML - Centro { p_werks } | &&
          |Período { p_poper }/{ p_bdatj } - Preço { p_prtyp }| ).

        DATA(lo_cols) = lo_salv->get_columns( ).
        lo_cols->set_optimize( abap_true ).

        " Títulos e moeda das colunas de valor
        DATA(lo_col) = lo_cols->get_column( 'ELEMT' ).
        lo_col->set_short_text( 'Elem.' ).
        lo_col->set_medium_text( 'Elemento' ).

        lo_col = lo_cols->get_column( 'TXELE' ).
        lo_col->set_medium_text( 'Denom.elemento' ).
        lo_col->set_long_text( 'Denominação elemento custo' ).

        LOOP AT VALUE stringtab( ( `TOTAL` ) ( `FIXO` ) ( `VARIA` ) )
             INTO DATA(lv_colname).
          lo_col = lo_cols->get_column( CONV #( lv_colname ) ).
          lo_col->set_currency_column( 'WAERS' ).
        ENDLOOP.

        lo_col = lo_cols->get_column( 'TOTAL' ).
        lo_col->set_medium_text( 'Total' ).
        lo_col = lo_cols->get_column( 'FIXO' ).
        lo_col->set_medium_text( 'Fixo' ).
        lo_col = lo_cols->get_column( 'VARIA' ).
        lo_col->set_medium_text( 'Variável' ).

        " Ordenação com subtotal por material
        DATA(lo_sorts) = lo_salv->get_sorts( ).
        lo_sorts->add_sort( columnname = 'MATNR'
                            subtotal   = abap_true ).
        lo_sorts->add_sort( columnname = 'BWTAR' ).

        DATA(lo_aggr) = lo_salv->get_aggregations( ).
        lo_aggr->add_aggregation( columnname  = 'TOTAL' ).
        lo_aggr->add_aggregation( columnname  = 'FIXO' ).
        lo_aggr->add_aggregation( columnname  = 'VARIA' ).

        lo_salv->display( ).

      CATCH cx_salv_msg cx_salv_not_found
            cx_salv_existing cx_salv_data_error INTO DATA(lx_salv).
        MESSAGE lx_salv->get_text( ) TYPE 'E'.
    ENDTRY.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
START-OF-SELECTION.
  NEW lcl_report( )->run( ).
