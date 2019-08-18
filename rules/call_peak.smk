def get_genrich_replicates(wildcards):
    sample_condition, assembly = wildcards.fname.split('-')
    if not 'condition' in samples.columns \
    or (sample_condition in samples.index and not sample_condition in samples['condition'].values):
        return expand(f"{{result_dir}}/{{dedup_dir}}/{wildcards.fname}.sambamba-queryname.bam", **config)
    else:
        return expand([f"{{result_dir}}/{{dedup_dir}}/{replicate}-{assembly}.sambamba-queryname.bam"
        for replicate in samples[(samples['assembly'] == assembly) & (samples['condition'] == sample_condition)].index], **config)


rule genrich_pileup:
    input:
        get_genrich_replicates
    output:
        bedgraphish=expand("{result_dir}/genrich/{{fname}}.bdgish", **config),
        log=expand("{result_dir}/genrich/{{fname}}.log", **config)
    log:
        expand("{log_dir}/genrich_pileup/{{fname}}_pileup.log", **config)
    benchmark:
        expand("{benchmark_dir}/genrich_pileup/{{fname}}.benchmark.txt", **config)[0]
    conda:
        "../envs/genrich.yaml"
    params:
        config['peak_caller'].get('genrich', " ")  # TODO: move this to config.schema.yaml
    threads: 15  # TODO: genrich uses lots of ram. Get the number from benchmark, instead of doing it through threads
    shell:
        """
        input=$(echo {input} | tr ' ' ',')
        Genrich -X -t $input -f {output.log} -k {output.bedgraphish} {params} -v > {log} 2>&1
        """


rule call_peak_genrich:
    input:
        log=expand("{result_dir}/genrich/{{fname}}.log", **config)
    output:
        narrowpeak= expand("{result_dir}/genrich/{{fname}}_peaks.narrowPeak", **config)
    log:
        expand("{log_dir}/call_peak_genrich/{{fname}}_peak.log", **config)
    benchmark:
        expand("{benchmark_dir}/call_peak_genrich/{{fname}}.benchmark.txt", **config)[0]
    conda:
        "../envs/genrich.yaml"
    params:
        config['peak_caller'].get('genrich', "")
    threads: 1
    shell:
        "Genrich -P -f {input.log} -o {output.narrowpeak} {params} -v > {log} 2>&1"


config['macs2_types'] = ['control_lambda.bdg', 'summits.bed', 'peaks.narrowPeak',
                         'peaks.xls', 'treat_pileup.bdg']
def get_fastqc(wildcards):
    if config['layout'].get(wildcards.sample, False) == "SINGLE":
        return expand("{result_dir}/{trimmed_dir}/{{sample}}_trimmed_fastqc.zip", **config)
    return sorted(expand("{result_dir}/{trimmed_dir}/{{sample}}_{fqext1}_trimmed_fastqc.zip", **config))

rule macs2_callpeak:
    #
    # Calculates genome size based on unique kmers of average length
    #
    input:
        bam=expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.samtools-coordinate.bam", **config),
        fastqc=get_fastqc
    output:
        expand("{result_dir}/macs2/{{sample}}-{{assembly}}_{macs2_types}", **config)
    log:
        expand("{log_dir}/macs2_callpeak/{{sample}}-{{assembly}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/macs2_callpeak/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    params:
        name=lambda wildcards, input: f"{wildcards.sample}" if config['layout'][wildcards.sample] == 'SINGLE' else \
                                      f"{wildcards.sample}_{config['fqext1']}",
        genome=f"{config['genome_dir']}/{{assembly}}/{{assembly}}.fa",
        macs_params=config['peak_caller'].get('macs2', "")  # TODO: move to config.schema.yaml
    conda:
        "../envs/macs2.yaml"
    shell:
        f"""
        # extract the kmer size, and get the effective genome size from it
        kmer_size=$(unzip -p {{input.fastqc}} {{params.name}}_trimmed_fastqc/fastqc_data.txt  | grep -P -o '(?<=Sequence length\\t).*' | grep -P -o '\d+$');
        GENSIZE=$(unique-kmers.py {{params.genome}} -k $kmer_size --quiet 2>&1 | grep -P -o '(?<=\.fa: ).*');
        echo "kmer size: $kmer_size, and effective genome size: $GENSIZE" >> {{log}}

        # call peaks
        macs2 callpeak --bdg -t {{input.bam}} --outdir {config['result_dir']}/macs2/ -n {{wildcards.sample}}-{{wildcards.assembly}} \
        {{params.macs_params}} -g $GENSIZE > {{log}} 2>&1
        """


rule hmmratac_genome_info:
    input:
        bam=expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.samtools-coordinate.bam", **config)
    output:
        out=expand("{result_dir}/hmmratac/{{sample}}-{{assembly}}.genomesizes", **config),
        tmp1=temp(expand("{result_dir}/hmmratac/{{sample}}-{{assembly}}.tmp1", **config)),
        tmp2=temp(expand("{result_dir}/hmmratac/{{sample}}-{{assembly}}.tmp2", **config))
    log:
        expand("{log_dir}/hmmratac_genome_info/{{sample}}-{{assembly}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/hmmratac_genome_info/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    conda:
        "../envs/samtools.yaml"
    shell:
        """
        samtools view -H {input} | grep SQ | cut -f 2-3 | cut -d ':' -f 2   | cut -f 1        > {output.tmp1}
        samtools view -H {input} | grep SQ | cut -f 2-3 | cut -d ':' -f 2,3 | cut -d ':' -f 2 > {output.tmp2}
        paste {output.tmp1} {output.tmp2} > {output.out}
        """


config['hmmratac_types'] = ['.log', '.model', '_peaks.gappedPeak', '_summits.bed', '.bedgraph']

rule hmmratac:
    input:
        genome_size=expand("{result_dir}/hmmratac/{{sample}}-{{assembly}}.genomesizes", **config),
        bam_index=expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.samtools-coordinate.bai", **config),
        bam=expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.samtools-coordinate.bam", **config)
    output:
        expand("{result_dir}/hmmratac/{{sample}}-{{assembly}}{hmmratac_types}", **config)
    log:
        expand("{log_dir}/hmmratac/{{sample}}-{{assembly}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/hmmratac/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    params:
        basename=lambda wildcards: expand(f"{{result_dir}}/hmmratac/{wildcards.sample}-{wildcards.assembly}", **config)
    conda:
        "../envs/hmmratac.yaml"
    shell:
        """
        HMMRATAC --bedgraph true -o {params.basename} -Xmx22G -b {input.bam} -i {input.bam_index} -g {input.genome_size}
        """


if 'condition' in samples:
    def get_replicates(wildcards):
        return expand([f"{{result_dir}}/{wildcards.peak_caller}/{replicate}-{wildcards.assembly}_peaks.narrowPeak"
               for replicate in samples[(samples['assembly'] == wildcards.assembly) & (samples['condition'] == wildcards.condition)].index], **config)

    if 'idr' in config.get('combine_replicates', "").lower():
        ruleorder: macs2_callpeak > call_peak_genrich > idr
        rule idr:
            input:
                get_replicates
            output:
                expand("{result_dir}/{{peak_caller}}/{{condition}}-{{assembly}}_peaks.narrowPeak", **config),
            log:
                expand("{log_dir}/idr/{{condition}}-{{assembly}}-{{peak_caller}}.log", **config)
            benchmark:
                expand("{benchmark_dir}/idr/{{condition}}-{{assembly}}-{{peak_caller}}.benchmark.txt", **config)[0]
            params: ""
            conda:
                "../envs/idr.yaml"
            shell:
                """
                idr --samples {input} {params} --output-file {output}
                """

    elif 'fisher' is config.get('combine_replicates', "").lower():
        raise NotImplementedError
