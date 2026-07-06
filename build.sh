# @Author: Ethan
# @Date:   2016-05-27 15:25:31
# @Last Modified by:   Ethan
# @Last Modified time: 2016-05-27 15:58:09

fakeapp_script=./fakeapp.sh;
fakeapp_bin=./bin/fakeapp;
working_tmp=$(mktemp -t fakeapp -d);

trap 'rm -rfv $working_tmp' EXIT SIGHUP SIGINT SIGQUIT;

main () {
	echo "> Packing fakesample..."
	local fakesample_package=fakesample.tgz;
	tar czvf $working_tmp/$fakesample_package fakesample;
	cp ./fakeapp.sh $fakeapp_bin;
	printf "fakesample_package=\"" >> $fakeapp_bin;
	base64 -b 100 -i "$working_tmp/$fakesample_package" >> $fakeapp_bin;
	echo "\"" >> $fakeapp_bin;

	echo "> Packing skills..."
	local skill_package=fakeapp_skill.tgz;
	# Pack the contents of skills/ so it unpacks to <tmp>/skills/<name>.
	tar czvf $working_tmp/$skill_package -C skills .;
	printf "fakeapp_skill_package=\"" >> $fakeapp_bin;
	base64 -b 100 -i "$working_tmp/$skill_package" >> $fakeapp_bin;
	echo "\"" >> $fakeapp_bin;

	echo "main;" >> $fakeapp_bin;
}

main;
