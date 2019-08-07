ruleorder: trim_galore_PE > trim_galore_SE

rule trim_galore_SE:
    input:
        expand("{result_dir}/{fastq_dir}/{{sample}}.{fqsuffix}.gz", **config)
    output:
        se=expand("{result_dir}/{trimmed_dir}/{{sample}}_trimmed.{fqsuffix}.gz", **config),
        qc=expand("{result_dir}/{trimmed_dir}/{{sample}}.{fqsuffix}.gz_trimming_report.txt", **config)
    conda:
        "../envs/trimgalore.yaml"
    threads: 6
    log:
        expand("{log_dir}/trim_galore_SE/{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/trim_galore_SE/{{sample}}.benchmark.txt", **config)[0]
    params:
        config=config['trim_galore'],
        fqsuffix=config['fqsuffix']
    shell:
        """
        cpulimit --include-children -l {threads}00 --\
        trim_galore -j {threads} {params.config} -o $(dirname {output.se}) {input} > {log} 2>&1

        # now rename to proper output
        if [ "{params.fqsuffix}" != "fq" ]; then
          mv "$(dirname {output.se})/{wildcards.sample}_trimmed.fq.gz" {output.se}
        fi 
        """


rule trim_galore_PE:
    input:
        r1=expand("{result_dir}/{fastq_dir}/{{sample}}_{fqext1}.{fqsuffix}.gz", **config),
        r2=expand("{result_dir}/{fastq_dir}/{{sample}}_{fqext2}.{fqsuffix}.gz", **config)
    output:
        r1=expand("{result_dir}/{trimmed_dir}/{{sample}}_{fqext1}_trimmed.{fqsuffix}.gz", **config),
        r2=expand("{result_dir}/{trimmed_dir}/{{sample}}_{fqext2}_trimmed.{fqsuffix}.gz", **config),
        qc=expand("{result_dir}/{trimmed_dir}/{{sample}}_{fqext}.{fqsuffix}.gz_trimming_report.txt", **config)
    conda:
        "../envs/trimgalore.yaml"
    threads: 6
    log:
        expand("{log_dir}/trim_galore_PE/{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/trim_galore_PE/{{sample}}.benchmark.txt", **config)[0]
    params:
        config=config['trim_galore'],
        fqsuffix=config['fqsuffix']
    shell:
        """
        cpulimit --include-children -l {threads}00 --\
        trim_galore --paired -j {threads} {params.config} -o $(dirname {output.r1}) {input.r1} {input.r2} > {log} 2>&1

        # now rename to proper output
        for f in $(find "$(dirname {output.r1})/" -name "{wildcards.sample}_*val_*.fq.gz"); do
            mv "$f" "$(echo "$f" | sed s/.fq/.{params.fqsuffix}/)"; done
        for f in $(find "$(dirname {output.r1})/" -maxdepth 1 -name "{wildcards.sample}_*val_*.fastq.gz"); do
            mv "$f" "$(echo "$f" | sed s/_val_./_trimmed/)"; done
        """
