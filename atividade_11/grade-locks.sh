#!/bin/bash
# Usage: grade dir_or_archive [output]

# Default locale to UTF-8
if [ -z "$LANG" ]; then
   LANG=en_US.UTF-8
   export LANG=en_US.UTF-8
fi

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|rar|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|rar|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".rar" ]; then
  UNRAR_SCREWING_UP_UNICODE="/tmp/$BASE-test/unrar_workaround.rar"
  cp "$INFILE" "$UNRAR_SCREWING_UP_UNICODE"
  unrar x "$UNRAR_SCREWING_UP_UNICODE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
cc -std=c11 tools/wrap-function.c -o tools/wrap-function \
  || echo "Compilation of wrap-function.c failed. If you are on a Mac, brace for impact"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

if ( ! grep -E -- '-[0-9]+' grade &> /dev/null ); then
   echo -e "Grade for $BASE$EXT: $(cat grade)"
fi

cleanup || true

exit 0

__TESTBENCH_MARKER__
�      �<�r�F�~�W�`�R$x�ho$ӱbӉ*����$uD���!�\$��1[��uN�~��t����#k�����}zzfZ�h]Pל6�}�ւ�������nK�Mڽ�v��p��~��}���촶��c)kq!��^��b�U��M[��?�<'�"^������Y��NZ��W��7ƱkF��ޒ���6����N�}��n����_n����m^�T��d���t0zqp��U�ʋ���A������m��%��{��B�19#B�7�"�{$�R����1&k�jN=��@�y0׋�؋]kCM@�툴����?�8�k�8g�iDD�!R��[l9�&�t�ZA�8!�s)<P'�읫��0����`�ܖ�ݼ8���,����w����n���]���k:�E��0�lO�>Q��v'�>˱/�}��k�Rl7"����f>�)�}E5b�Q����DĜA��{�x��5�)�� �M�!��c����9T�p�9�����p�-���k������&fJ^.��}�4�H6zd;���S�XS_�Ƅ�$�;���U��Y��%�ŁKڼ��i 4H��x?�Aj�&��><����茐}�/F�Y�<����p��pX�q"��I����YH#�A����$��Qo��Z�e����$){��͂��PA*
�ۣF���W
�A�ᰳ�A�����W��AcpU�p���ut=��c�J��wf��y55낶%#��Qۈ�]�L�<�m�1��Z*I���|dn�7n��[4�(�]��բ���d��zR����;DW6�3,^b�R�fD���rDd�)-�5���0"�5��h��o�O��ըv^�e}�a�?mU�JՆC������p��')N�/�!�,��;�h+��õ�>��g�Y��M�y�t���~�������6�ϩ?1$X�>VS�ܲ�em����A,=9�V���\M=ا�uWe���d ��'e2��ι�P�#����紽�������Rbѱ��,�� �ᾭ���t)��x=[Ϫ�1i-��@��*\NG(6%����P
�K���t�L%R�&�Y�fM`�����ܼ�O�%{�R}H��i�>$
-�fcd$)��#�Yv��}M�d󹏿/cN�N��;;� ��������Ӡ������<<8��K���0� � �:g���-)M�� ��"à�b��Kg琉A<�@�|���"�AZ��O̟Y�,FW�9�i�is�Bȍ�52�(2�|�p+�jbĐ�7��gy�i����(�!�CX�DS�Q�! �p�i�K�@�1ʢ/G���+�<@�2,�^')t�bdi�fen�a%M���$�+rl:^H3!�b9|ꩿo#�B�W�$%~���c���d^�>�b�b�C�)��Y�</���&M��B�c&��רl�c�3�f�+��c'����C�0��X�#�XFd�+#dZ�@��<��n��"u��^��;�^�,$4�t��E�fFdN�n
�I��7g�;�4� NO�=>ѩ�� �D��.(a b��G��d�e�i6am������v@-r�6�%���c"�%t��:�K�Ap�r����95�L_)W{������_������p�Y���ab[׀��(H�l�6���Rv�zBKg8�\f#���bg��|dǝ%��9�� e�	Vq?�L���ι�U��s������Y�B�!fKȈ�*tݮ�6����[[U4]��P�7�7S�ϴ6��.�-Uc�4	[gP�����m	N�Ź�( H �	�+V��	�K^�0�J-l�>ĉ�#�_0����j�H+��Oâ�+În�Ɗ��Ng����m=Z���E����������`�W�(�^�>�*��at����^eGy��?�f����JWA�!����W%>��i�˦;��8v�,�Ե�R#Ȉ.���'DÁXl;V@�^E����߶z����H�U̧0v�;^�%�[�"�x�'n�8��?��7�YL�9T	��r w��?O����I�0aDZ6� �o��܋��>�0��+r���Ij:D{;�7�׿���v�����O�����e}����JH����t]W�^�xe��]�X^�t��1��>�o6)��.蜒�!;�4�O�)�p����P��ol ��j!TzX�}A�%�P{!dZ����R�'!F!9�����H`7�BbA�y�:��O��x�~H/	�����V�6!
�h�g.��F�|��o�h0��m�X��o?*������������������1��w����'�S���0�\��n4|�k���=���b4cJ��|���D� ���r�ۡ�Ј���c.���^�N���Y��sX��9�w�?%��Ш{���"���������	�2H�?�5O}������+�]D���c3�1i����SjX�m��i��������� �G��ȰܪhZ�ծV"�,���{^�]� � 2�(���UDL��o$P��--�Z�GZ}U��@�̐�(?~���l���Oz�,'R+O�\A��1_N6����Au桶e�s�ۅ�7�
�~`{� �	�=j�V�I��9�Aȓ's�2�$l�i��;_^H�)���.��S*SR��cx�q�A�{~�I��_��x��	��R]���5LM��j���LL-<�ă�8���!��Β���nn���]� ]+d�>��C��j6'�U�<�
e�w����/�����j\�HcE�,�s���u�ߝ4����W��qh�Fd_�D�v��f��/��Ʈ���o���ÐQ���:ֵn������sq�����v�� 0��a�5�������S:3���u�4�2I����b3�k ������$������(�ll����#�A�t0��C|�<{o��o_A�ΆtpDnH��ǃ)^�=$�� ��+	����<e6�x�(���"jϽ+2�hxW!9��$b?�V�ڤ>KV��7<#�tq����@��Zu������ʟ>�s؜����K.�|jO��͝Įk\@���j��Mdc�B<g���9���؀u�c�c^\�O�Ǆ�����.�ۢ�^�$ ��(l�d:(������(���Syi�0��(u�L@���h9���p�f�)L��aY''����HK\�����`�ͥ��D��xv���8�M����8�>��L��ʊ��=�^�Ԍؽ�L��7T{���]$����~`Mx�r��
�/uҩ.��E�����D�:�����xY�����Zh��n@��g���D�of#i�ѫW���u��/��q}��m[�Ol�΍���,��.-^1�ܩ�]/X�wyD�N������ ��e��^6��/�9K}v�y��N��+��U!#S�s���(���j�ꂼ��Σ2���K���/��V�ݖ�.]�zW�g�vF�<���b^\��b���ЭŐ6 >6�R�É��;/1bI$3*����)�>o�
jb�s�;��Q���~�����7�&o鏺%[�#S�95`�Y
:��Z�L�-�É*�Z=r7��U�D+�'�L��d�^��a�oG9�%�fӧ��	��a�X��s.)�<]_�`j�a(�S>��(�$���lB�0`gM?��#t��(�!���;��-#��Lw5�ʢ!L��%&K�����S�������������(# �Pv���>��|��d���/��z~����F%�`fG�>�F���Rͦc_P�(�ꉡa<0)�yɲ�v>L�	gH�G�ش�yq�șrU[v���ܲ?���K
~�bV-c���/K�z��G�.�ܯv�&�
��s7�K�#���B����8s��a�aD\�f��<)9�.d�t�v�eX7�15�c�H'D���l�kmI��W��N��H1TXy�1�#O�b�c�4`:��-v }�d��QX�(�P]1WЎ%����^�ժuZ�.$ʫ�~�r����;��yɮ�о�� �)=U��.�K�����m�g���,��{P�x�+0,?��G�~�~
��'�mI�
zk<Y�,-�;�r�&�E� i��5{�zX�O�2/6�e1�*���d��pBrQ�LJ�[�U���ņ��nB��p��&�F��s���ȳ�_'6��z8�e+�vv���ߝ������]4��˴�nL�dNQc� $�&v6�y4��)ݠ6�����os�@�ѣ�����z��W���Rv�S�t
K;i��ޢ�iV��1� ��Z�ⰼ���M*�^�pԃW%)_x�B<��*�֛�^��̳��5���|*�8�� 4r� �Y��<dO��h+XG���1��'�%� ����W�:aX�����F�ь�}�9�r�	����)5/�1=� �XYP��g�� ��J��Ѽ�T�`HLxd�[�����9L�6���+^6B^k��nCs��˵����f:L�ʩ$B�(�!m	�����2��	�d�홸/�w�k�O�y3�H��aF����P-�D�i�h��/�b�T����ao�v��d�����������>��(�e��`ǁ�gF�3Fh/�3fc���{D�}'�[�y���HE�x�x�3GH��T�K�߂P�|���J��^���Z��������� ?�<�A��6�8�cȺ�@6�{��8D*���9J�_ہ%�b�����Y��!�
����l0��ƌ$ �|��o�p ��Ő��D2,OU�f."�i�N�
���*%��Y���yU�k���<�7%�0g�)fs�&��>��уA�� HQD��}�Z+1���JģMX'�!�S!o!A�
*/�T;[�i�|�`8|l#Qm�UuU����������h�d�'Ĵ�&wn"�J!Ú����ݒ���Ǐ7��^lf��Ho����&�;����7����Aɽ6���ˮ��=���Hs��]|�'�|�����e:U��-�ɥ��˘:�;�S�0%�3?�:Q :z3Q���:�:�O�G&�;���hd����Ih\�*����@W@jE�r�ۮ��ʌ��՟.o_�u[�u[�u[�u[�u[�u[�u[�u[�u[�u[�u[�u[�u[�u[�u������  x  