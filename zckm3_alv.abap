*&---------------------------------------------------------------------*
*& Report  ZCKM3_ALV
*&---------------------------------------------------------------------*
*& Estratificação por elemento de custo (visão CKM3N) em ALV,
*& multi-material / multi-lote, a partir do split de preço do
*& Material Ledger.
*&
*& Fonte de dados : MLCCS_READ_PR (lê CKMLKEPH via IT_KALNR/ET_PRKEPH)
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

" Mapeamento elemento de custo -> campos KSTnnn (custos totais / fixos)
TYPES: BEGIN OF ty_map,
         elemt TYPE tckh1-elemt,
         fdnrv TYPE n LENGTH 2,   " nº campo de custo: custos totais
         fdnrf TYPE n LENGTH 2,   " nº campo de custo: parte fixa
       END OF ty_map.
TYPES ty_map_tab TYPE STANDARD TABLE OF ty_map WITH EMPTY KEY.

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
              p_elehk TYPE tckh1-elehk,            " esquema (vazio=autom.)
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
          mt_prkeph TYPE mlccs_t_prkeph,
          mt_prkeko TYPE mlccs_t_prkeko,
          mt_txele  TYPE HASHED TABLE OF tckh1
                         WITH UNIQUE KEY elehk elemt,
          mt_map    TYPE ty_map_tab,
          mv_elehk  TYPE tckh1-elehk,
          mv_waers  TYPE waers.

    METHODS: seleciona_materiais,
             le_split_ml,
             carrega_textos,
             carrega_mapa,
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
    carrega_textos( ).
    carrega_mapa( ).
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

  ENDMETHOD.

  METHOD le_split_ml.

    DATA: lt_kalnr TYPE ckmv0_matobj_tbl.

    " Objetos de custeio: 1 entrada por número de cálculo/área avaliação
    LOOP AT mt_mat ASSIGNING FIELD-SYMBOL(<ls_mat>).
      APPEND INITIAL LINE TO lt_kalnr ASSIGNING FIELD-SYMBOL(<ls_key>).
      <ls_key>-kalnr = <ls_mat>-kalnr.
      <ls_key>-bwkey = <ls_mat>-bwkey.
    ENDLOOP.

    " Leitura oficial do split de preço do Material Ledger (CKMLKEPH).
    " Retorna todas as linhas do período: tipos de preço, moedas,
    " split principal/auxiliar, totais e parte fixa — o filtro é
    " feito na montagem da saída.
    CALL FUNCTION 'MLCCS_READ_PR'
      EXPORTING
        i_use_buffer = space
        i_bdatj_1    = p_bdatj
        i_poper_1    = p_poper
        i_untper     = '000'
      IMPORTING
        et_prkeko    = mt_prkeko
        et_prkeph    = mt_prkeph
      TABLES
        it_kalnr     = lt_kalnr
      EXCEPTIONS
        no_data_found           = 1
        input_data_inconsistent = 2
        OTHERS                  = 3.

    IF sy-subrc <> 0.
      CLEAR: mt_prkeko, mt_prkeph.
    ENDIF.

  ENDMETHOD.

  METHOD carrega_textos.

    " Esquema de elementos: o informado na tela ou, se vazio,
    " determinado automaticamente do cabeçalho do split (CKMLPRKEKO,
    " campo ELEHK = esquema principal; ELEHKNS = secundário)
    mv_elehk = p_elehk.
    IF mv_elehk IS INITIAL.
      LOOP AT mt_prkeko ASSIGNING FIELD-SYMBOL(<ls_keko>)
           WHERE elehk IS NOT INITIAL.
        mv_elehk = <ls_keko>-elehk.
        EXIT.
      ENDLOOP.
    ENDIF.

    " Textos no idioma de logon
    SELECT * FROM tckh1
      WHERE spras = @sy-langu
        AND elehk = @mv_elehk
      INTO TABLE @mt_txele.

    " Fallback: textos em qualquer idioma disponível
    IF mt_txele IS INITIAL.
      SELECT * FROM tckh1
        WHERE elehk = @mv_elehk
        INTO TABLE @DATA(lt_txele).
      SORT lt_txele BY elemt spras.
      DELETE ADJACENT DUPLICATES FROM lt_txele COMPARING elemt.
      LOOP AT lt_txele ASSIGNING FIELD-SYMBOL(<ls_txt>).
        INSERT <ls_txt> INTO TABLE mt_txele.
      ENDLOOP.
    ENDIF.

  ENDMETHOD.

  METHOD carrega_mapa.

    " Cada elemento do esquema possui campos de custo (KSTnnn)
    " próprios para custos totais e parte fixa, não necessariamente
    " adjacentes. A atribuição fica na TCKH3; o nome dos campos com
    " o nº do campo de custo varia por release, por isso a descoberta
    " é dinâmica.
    TYPES: BEGIN OF ty_cand,
             tot TYPE fieldname,
             fix TYPE fieldname,
           END OF ty_cand.
    TYPES ty_cand_tab TYPE STANDARD TABLE OF ty_cand WITH EMPTY KEY.

    DATA(lt_cand) = VALUE ty_cand_tab(
      ( tot = 'FELDNRV' fix = 'FELDNRF' )
      ( tot = 'FDNRV'   fix = 'FDNRF'   )
      ( tot = 'FELDNR'  fix = 'FELDNRF' ) ).

    DATA: lv_tot TYPE fieldname,
          lv_fix TYPE fieldname.

    FIELD-SYMBOLS <lv_val> TYPE any.

    SELECT * FROM tckh3
      WHERE elehk = @mv_elehk
      INTO TABLE @DATA(lt_tckh3).
    IF lt_tckh3 IS INITIAL.
      RETURN.
    ENDIF.

    READ TABLE lt_tckh3 ASSIGNING FIELD-SYMBOL(<ls_h3>) INDEX 1.

    LOOP AT lt_cand INTO DATA(ls_cand).
      ASSIGN COMPONENT ls_cand-tot OF STRUCTURE <ls_h3>
        TO FIELD-SYMBOL(<lv_chk1>).
      CHECK sy-subrc = 0.
      ASSIGN COMPONENT ls_cand-fix OF STRUCTURE <ls_h3>
        TO FIELD-SYMBOL(<lv_chk2>).
      CHECK sy-subrc = 0.
      lv_tot = ls_cand-tot.
      lv_fix = ls_cand-fix.
      EXIT.
    ENDLOOP.

    IF lv_tot IS INITIAL.
      " Diagnóstico: informa os campos reais da TCKH3 para ajuste
      DATA(lo_type) = CAST cl_abap_structdescr(
                        cl_abap_typedescr=>describe_by_name( 'TCKH3' ) ).
      DATA(lv_flds) = ``.
      LOOP AT lo_type->components ASSIGNING FIELD-SYMBOL(<ls_comp>).
        lv_flds = |{ lv_flds } { <ls_comp>-name }|.
      ENDLOOP.
      MESSAGE |Campos de custo não identificados na TCKH3:{ lv_flds }|
        TYPE 'I'.
      RETURN.
    ENDIF.

    LOOP AT lt_tckh3 ASSIGNING <ls_h3>.
      APPEND INITIAL LINE TO mt_map ASSIGNING FIELD-SYMBOL(<ls_map>).
      ASSIGN COMPONENT 'ELEMT' OF STRUCTURE <ls_h3> TO <lv_val>.
      IF sy-subrc = 0.
        <ls_map>-elemt = <lv_val>.
      ENDIF.
      ASSIGN COMPONENT lv_tot OF STRUCTURE <ls_h3> TO <lv_val>.
      IF sy-subrc = 0.
        <ls_map>-fdnrv = <lv_val>.
      ENDIF.
      ASSIGN COMPONENT lv_fix OF STRUCTURE <ls_h3> TO <lv_val>.
      IF sy-subrc = 0.
        <ls_map>-fdnrf = <lv_val>.
      ENDIF.
    ENDLOOP.

    DELETE mt_map WHERE fdnrv IS INITIAL.
    SORT mt_map BY elemt.

  ENDMETHOD.

  METHOD monta_saida.

    DATA: ls_out   TYPE ty_out,
          lv_field TYPE fieldname,
          lv_nr    TYPE i,
          lt_map   TYPE ty_map_tab.

    FIELD-SYMBOLS: <lv_val> TYPE any.

    " Sem mapeamento da TCKH3, exibe os campos KST 1:1 (modo degradado)
    lt_map = mt_map.
    IF lt_map IS INITIAL.
      lt_map = VALUE #( FOR i = 1 WHILE i <= 40
                        ( elemt = i fdnrv = i ) ).
    ENDIF.

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

      " Linha do split (KKZST = ' ') do tipo de preço/moeda
      " solicitados, estratificação principal (KEART = 'H').
      " Custos totais e parte fixa ficam na MESMA linha, em campos
      " de custo distintos por elemento (mapeados na TCKH3).
      READ TABLE mt_prkeph ASSIGNING FIELD-SYMBOL(<ls_split>)
           WITH KEY kalnr = <ls_mat>-kalnr
                    curtp = p_curtp
                    keart = 'H'
                    prtyp = p_prtyp
                    kkzst = space.
      CHECK sy-subrc = 0.

      READ TABLE lt_cr INTO DATA(ls_cr)
           WITH KEY kalnr = <ls_mat>-kalnr BINARY SEARCH.
      IF sy-subrc <> 0.
        CLEAR ls_cr.
      ENDIF.

      LOOP AT lt_map ASSIGNING FIELD-SYMBOL(<ls_map>).

        CLEAR ls_out.
        ls_out-elemt = <ls_map>-elemt.

        " Custos totais do elemento
        lv_nr = <ls_map>-fdnrv.
        CHECK lv_nr BETWEEN 1 AND 40.
        lv_field = |KST{ lv_nr WIDTH = 3 PAD = '0' ALIGN = RIGHT }|.
        ASSIGN COMPONENT lv_field OF STRUCTURE <ls_split> TO <lv_val>.
        CHECK sy-subrc = 0.
        ls_out-total = <lv_val>.

        " Parte fixa do elemento (campo de custo próprio)
        lv_nr = <ls_map>-fdnrf.
        IF lv_nr BETWEEN 1 AND 40.
          lv_field = |KST{ lv_nr WIDTH = 3 PAD = '0' ALIGN = RIGHT }|.
          ASSIGN COMPONENT lv_field OF STRUCTURE <ls_split> TO <lv_val>.
          IF sy-subrc = 0.
            ls_out-fixo = <lv_val>.
          ENDIF.
        ENDIF.

        ls_out-varia = ls_out-total - ls_out-fixo.

        " Suprime elementos sem texto no esquema E sem valor
        READ TABLE mt_txele ASSIGNING FIELD-SYMBOL(<ls_txt>)
             WITH TABLE KEY elehk = mv_elehk
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

      ENDLOOP.

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
        lo_col->set_short_text( 'Denom.' ).
        lo_col->set_medium_text( 'Denom.elemento' ).
        lo_col->set_long_text( 'Denominação elemento custo' ).

        LOOP AT VALUE stringtab( ( `TOTAL` ) ( `FIXO` ) ( `VARIA` ) )
             INTO DATA(lv_colname).
          lo_col = lo_cols->get_column( CONV #( lv_colname ) ).
          lo_col->set_currency_column( 'WAERS' ).
        ENDLOOP.

        lo_col = lo_cols->get_column( 'TOTAL' ).
        lo_col->set_short_text( 'Total' ).
        lo_col->set_medium_text( 'Total' ).
        lo_col->set_long_text( 'Total' ).
        lo_col = lo_cols->get_column( 'FIXO' ).
        lo_col->set_short_text( 'Fixo' ).
        lo_col->set_medium_text( 'Fixo' ).
        lo_col->set_long_text( 'Fixo' ).
        lo_col = lo_cols->get_column( 'VARIA' ).
        lo_col->set_short_text( 'Variável' ).
        lo_col->set_medium_text( 'Variável' ).
        lo_col->set_long_text( 'Variável' ).

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
